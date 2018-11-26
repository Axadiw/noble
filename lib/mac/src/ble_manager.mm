//
//  ble_manager.mm
//  noble-mac-native
//
//  Created by Georg Vienna on 28.08.18.
//
#include "ble_manager.h"

#import <Foundation/Foundation.h>

#include "objc_cpp.h"
#include <sstream>

#define LOGE(message, ...) \
{\
    char buff[255];\
    snprintf(buff, sizeof(buff), ": " message, __VA_ARGS__);\
    std::string buffAsStdStr = __FUNCTION__;\
    buffAsStdStr += buff;\
    emit.Log(buffAsStdStr);\
}

const char* description(NSError *error) {
    auto description = [error description];
    if(description != nil) {
        auto str = [description UTF8String];
        if(str != NULL) {
            return str;
        }
    }
    return "<no description>";
}

@implementation BLEManager
- (instancetype)init   {
    if (self = [super init]) {
        pendingRead = false;
        self.dispatchQueue = dispatch_queue_create("CBqueue", 0);
        self.centralManager = [[CBCentralManager alloc] initWithDelegate:self queue:self.dispatchQueue];
        self.peripherals = [NSMutableDictionary dictionaryWithCapacity:10];
    }
    return self;
}

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    auto state = stateToString(central.state);
    emit.RadioState(state);
}

- (void)scan: (NSArray<CBUUID *> *)serviceUUIDs allowDuplicates: (BOOL)allowDuplicates {
    NSDictionary *options = @{CBCentralManagerScanOptionAllowDuplicatesKey:[NSNumber numberWithBool:allowDuplicates]};
    [self.centralManager scanForPeripheralsWithServices:serviceUUIDs options:options];
    emit.ScanState(true);
}

- (void)stopScan {
    [self.centralManager stopScan];
    emit.ScanState(false);
}

- (void) centralManager:(CBCentralManager *)central didDiscoverPeripheral:(CBPeripheral *)peripheral advertisementData:(NSDictionary<NSString *,id> *)advertisementData RSSI:(NSNumber *)RSSI {
    std::string uuid = getUuid(peripheral);

    Peripheral p;
    p.address = getAddress(uuid, &p.addressType);
    IF(NSNumber*, connect, [advertisementData objectForKey:CBAdvertisementDataIsConnectable]) {
        p.connectable = [connect boolValue];
    }
    IF(NSString*, dataLocalName, [advertisementData objectForKey:CBAdvertisementDataLocalNameKey]) {
        p.name = [dataLocalName UTF8String];
    }
    if(p.name.empty()) {
        IF(NSString*, name, [peripheral name]) {
            p.name = [name UTF8String];
        }
    }
    IF(NSNumber*, txLevel, [advertisementData objectForKey:CBAdvertisementDataTxPowerLevelKey]) {
        p.txPowerLevel = [txLevel intValue];
    }
    IF(NSData*, data, [advertisementData objectForKey:CBAdvertisementDataManufacturerDataKey]) {
        const UInt8* bytes = (UInt8 *)[data bytes];
        p.manufacturerData.assign(bytes, bytes+[data length]);
    }
    IF(NSDictionary*, dictionary, [advertisementData objectForKey:CBAdvertisementDataServiceDataKey]) {
        for (CBUUID* key in dictionary) {
            IF(NSData*, value, dictionary[key]) {
                auto serviceUuid = [[key UUIDString] UTF8String];
                Data sData;
                const UInt8* bytes = (UInt8 *)[value bytes];
                sData.assign(bytes, bytes+[value length]);
                p.serviceData.push_back(std::make_pair(serviceUuid, sData));
            }
        }
    }
    IF(NSArray*, services, [advertisementData objectForKey:CBAdvertisementDataServiceUUIDsKey]) {
        for (CBUUID* service in services) {
            p.serviceUuids.push_back([[service UUIDString] UTF8String]);
        }
    }

    int rssi = [RSSI intValue];
    emit.Scan(uuid, rssi, p);
}

- (BOOL)connect:(NSString*) uuid {
    CBPeripheral *peripheral = [self.peripherals objectForKey:uuid];
    if(!peripheral) {
        NSArray* peripherals = [self.centralManager retrievePeripheralsWithIdentifiers:@[[[NSUUID alloc] initWithUUIDString:uuid]]];
        peripheral = [peripherals firstObject];
        if(peripheral) {
            peripheral.delegate = self;
            [self.peripherals setObject:peripheral forKey:uuid];
        } else {
            std::stringstream str;
            str << "Peripheral with uuid ";
            str << [uuid UTF8String];
            str << " not found!";
            emit.Connected([uuid UTF8String], str.str().c_str());
            return NO;
        }
    }
    NSDictionary* options = @{CBConnectPeripheralOptionNotifyOnDisconnectionKey: [NSNumber numberWithBool:YES]};
    [self.centralManager connectPeripheral:peripheral options:options];
    return YES;
}

- (void) centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral {
    std::string uuid = getUuid(peripheral);
    emit.Connected(uuid, "");
}

- (void) centralManager:(CBCentralManager *)central didFailToConnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    std::string uuid = getUuid(peripheral);
    std::string message = "Connection failed";
    if(error) {
        message += ": ";
        message += description(error);
    }
    emit.Connected(uuid, message);
}

- (BOOL)disconnect:(NSString*) uuid {
    IF(CBPeripheral*, peripheral, [self.peripherals objectForKey:uuid]) {
        auto state = peripheral.state;
        LOGE("disconnect called on %s state %ld", [uuid UTF8String], (long)state);
        [self.centralManager cancelPeripheralConnection:peripheral];
        return YES;
    }
    LOGE("peripheral not found %s", [uuid UTF8String]);
    return NO;
}

-(void) centralManager:(CBCentralManager *)central didDisconnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    std::string uuid = getUuid(peripheral);
    if(error) {
        LOGE("error %s %s", uuid.c_str(), description(error));
    }
    emit.Disconnected(uuid);
}

- (BOOL)updateRSSI:(NSString*) uuid {
    IF(CBPeripheral*, peripheral, [self.peripherals objectForKey:uuid]) {
        [peripheral readRSSI];
        return YES;
    }
    LOGE("peripheral not found %s", [uuid UTF8String]);
    return NO;
}

- (void)peripheralDidUpdateRSSI:(CBPeripheral *)peripheral error:(NSError *)error {
    std::string uuid = getUuid(peripheral);
    NSNumber* rssi = peripheral.RSSI;
    if(!error && rssi) {
        emit.RSSI(uuid, [rssi longValue]);
    }
}

#pragma mark - Services

-(BOOL) discoverServices:(NSString*) uuid serviceUuids:(NSArray<NSString*>*) services {
    IF(CBPeripheral*, peripheral, [self.peripherals objectForKey:uuid]) {
        NSMutableArray* servicesUuid = nil;
        if(services) {
            servicesUuid = [NSMutableArray arrayWithCapacity:[services count]];
            [services enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
                [servicesUuid addObject:[CBUUID UUIDWithString:obj]];
            }];
        }
        [peripheral discoverServices:servicesUuid];
        return YES;
    }
    LOGE("peripheral not found %s", [uuid UTF8String]);
    return NO;
}

- (void) peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error {
    std::string uuid = getUuid(peripheral);
    std::vector<std::string> services = getServices(peripheral.services);
    if(error) {
        LOGE("error %s %s", uuid.c_str(), description(error));
    }
    emit.ServicesDiscovered(uuid, services);
}

- (BOOL)discoverIncludedServices:(NSString*) uuid forService:(NSString*) serviceUuid services:(NSArray<NSString*>*) serviceUuids {
    IF(CBPeripheral*, peripheral, [self.peripherals objectForKey:uuid]) {
        IF(CBService*, service, [self getService:peripheral service:serviceUuid]) {
            NSMutableArray* includedServices = nil;
            if(serviceUuids) {
                includedServices = [NSMutableArray arrayWithCapacity:[serviceUuids count]];
                [serviceUuids enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
                    [includedServices addObject:[CBUUID UUIDWithString:obj]];
                }];
            }
            [peripheral discoverIncludedServices:includedServices forService:service];
            return YES;
        }
        LOGE("service not found %s %s", [uuid UTF8String], [serviceUuid UTF8String]);
        return NO;
    }
    LOGE("peripheral not found %s", [uuid UTF8String]);
    return NO;
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverIncludedServicesForService:(CBService *)service error:(NSError *)error {
    std::string uuid = getUuid(peripheral);
    auto serviceUuid = [[service.UUID UUIDString] UTF8String];
    if(error) {
        LOGE("error %s %s %s", uuid.c_str(), serviceUuid, description(error));
    }
    std::vector<std::string> services = getServices(service.includedServices);
    emit.IncludedServicesDiscovered(uuid, serviceUuid, services);
}

#pragma mark - Characteristics

- (BOOL)discoverCharacteristics:(NSString*) uuid forService:(NSString*) serviceUuid characteristics:(NSArray<NSString*>*) characteristics {
    IF(CBPeripheral *, peripheral, [self.peripherals objectForKey:uuid]) {
        IF(CBService*, service, [self getService:peripheral service:serviceUuid]) {
            NSMutableArray* characteristicsUuid = nil;
            if(characteristics) {
                characteristicsUuid = [NSMutableArray arrayWithCapacity:[characteristics count]];
                [characteristics enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
                    [characteristicsUuid addObject:[CBUUID UUIDWithString:obj]];
                }];
            }
            [peripheral discoverCharacteristics:characteristicsUuid forService:service];
            return YES;
        }
        LOGE("service not found %s %s", [uuid UTF8String], [serviceUuid UTF8String]);
        return NO;
    }
    LOGE("peripheral not found %s", [uuid UTF8String]);
    return NO;
}

-(void) peripheral:(CBPeripheral *)peripheral didDiscoverCharacteristicsForService:(CBService *)service error:(NSError *)error {
    std::string uuid = getUuid(peripheral);
    auto serviceUuid = [service.UUID.UUIDString UTF8String];
    if(error) {
        LOGE("error %s %s %s", uuid.c_str(), serviceUuid, description(error));
    }
    auto characteristics = getCharacteristics(service.characteristics);
    emit.CharacteristicsDiscovered(uuid, serviceUuid, characteristics);
}

- (BOOL)read:(NSString*) uuid service:(NSString*) serviceUuid characteristic:(NSString*) characteristicUuid {
    IF(CBPeripheral *, peripheral, [self.peripherals objectForKey:uuid]) {
        IF(CBCharacteristic*, characteristic, [self getCharacteristic:peripheral service:serviceUuid characteristic:characteristicUuid]) {
            pendingRead = true;
            [peripheral readValueForCharacteristic:characteristic];
            return YES;
        }
        LOGE("characteristic not found %s %s %s", [uuid UTF8String], [serviceUuid UTF8String], [characteristicUuid UTF8String]);
        return NO;
    }
    LOGE("peripheral not found %s", [uuid UTF8String]);
    return NO;
}

- (void) peripheral:(CBPeripheral *)peripheral didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    std::string uuid = getUuid(peripheral);
    auto serviceUuid = [characteristic.service.UUID.UUIDString UTF8String];
    auto characteristicUuid = [characteristic.UUID.UUIDString UTF8String];
    if(error) {
        LOGE("error %s %s %s %s", uuid.c_str(), serviceUuid, characteristicUuid, description(error));
    }
    const UInt8* bytes = (UInt8 *)[characteristic.value bytes];
    Data data;
    data.assign(bytes, bytes+[characteristic.value length]);
    bool isNotification = !pendingRead && characteristic.isNotifying;
    pendingRead = false;
    emit.Read(uuid, serviceUuid, characteristicUuid, data, isNotification);
}

- (BOOL)write:(NSString*) uuid service:(NSString*) serviceUuid characteristic:(NSString*) characteristicUuid data:(NSData*) data withoutResponse:(BOOL)withoutResponse {
    IF(CBPeripheral *, peripheral, [self.peripherals objectForKey:uuid]) {
        IF(CBCharacteristic*, characteristic, [self getCharacteristic:peripheral service:serviceUuid characteristic:characteristicUuid]) {
            CBCharacteristicWriteType type = withoutResponse ? CBCharacteristicWriteWithoutResponse : CBCharacteristicWriteWithResponse;
            [peripheral writeValue:data forCharacteristic:characteristic type:type];
            if (withoutResponse) {
                emit.Write([uuid UTF8String], [serviceUuid UTF8String], [characteristicUuid UTF8String]);
            }
            return YES;
        }
        LOGE("characteristic not found %s %s %s", [uuid UTF8String], [serviceUuid UTF8String], [characteristicUuid UTF8String]);
        return NO;
    }
    LOGE("peripheral not found %s", [uuid UTF8String]);
    return NO;
}

-(void) peripheral:(CBPeripheral *)peripheral didWriteValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    std::string uuid = getUuid(peripheral);
    auto serviceUuid = [characteristic.service.UUID.UUIDString UTF8String];
    auto characteristicUuid = [characteristic.UUID.UUIDString UTF8String];
    if(error) {
        LOGE("error %s %s %s %s", uuid.c_str(), serviceUuid, characteristicUuid, description(error));
    }
    emit.Write(uuid, serviceUuid, characteristicUuid);
}

- (BOOL)notify:(NSString*) uuid service:(NSString*) serviceUuid characteristic:(NSString*) characteristicUuid on:(BOOL)on {
    IF(CBPeripheral *, peripheral, [self.peripherals objectForKey:uuid]) {
        IF(CBCharacteristic*, characteristic, [self getCharacteristic:peripheral service:serviceUuid characteristic:characteristicUuid]) {
            [peripheral setNotifyValue:on forCharacteristic:characteristic];
            return YES;
        }
        LOGE("characteristic not found %s %s %s", [uuid UTF8String], [serviceUuid UTF8String], [characteristicUuid UTF8String]);
        return NO;
    }
    LOGE("peripheral not found %s", [uuid UTF8String]);
    return NO;
}

- (void)peripheral:(CBPeripheral *)peripheral didUpdateNotificationStateForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    std::string uuid = getUuid(peripheral);
    auto serviceUuid = [characteristic.service.UUID.UUIDString UTF8String];
    auto characteristicUuid = [characteristic.UUID.UUIDString UTF8String];
    if(error) {
        LOGE("error %s %s %s %s", uuid.c_str(), serviceUuid, characteristicUuid, description(error));
    }
    emit.Notify(uuid, serviceUuid, characteristicUuid, characteristic.isNotifying);
}

#pragma mark - Descriptors

- (BOOL)discoverDescriptors:(NSString*) uuid service:(NSString*) serviceUuid characteristic:(NSString*) characteristicUuid {
    IF(CBPeripheral *, peripheral, [self.peripherals objectForKey:uuid]) {
        IF(CBCharacteristic*, characteristic, [self getCharacteristic:peripheral service:serviceUuid characteristic:characteristicUuid]) {
            [peripheral discoverDescriptorsForCharacteristic:characteristic];
            return YES;
        }
        LOGE("characteristic not found %s %s %s", [uuid UTF8String], [serviceUuid UTF8String], [characteristicUuid UTF8String]);
        return NO;
    }
    LOGE("peripheral not found %s", [uuid UTF8String]);
    return NO;
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverDescriptorsForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    std::string uuid = getUuid(peripheral);
    auto serviceUuid = [characteristic.service.UUID.UUIDString UTF8String];
    auto characteristicUuid = [characteristic.UUID.UUIDString UTF8String];
    if(error) {
        LOGE("error %s %s %s %s", uuid.c_str(), serviceUuid, characteristicUuid, description(error));
    }
    std::vector<std::string> descriptors = getDescriptors(characteristic.descriptors);
    emit.DescriptorsDiscovered(uuid, serviceUuid, characteristicUuid, descriptors);
}

- (BOOL)readValue:(NSString*) uuid service:(NSString*) serviceUuid characteristic:(NSString*) characteristicUuid descriptor:(NSString*) descriptorUuid {
    IF(CBPeripheral *, peripheral, [self.peripherals objectForKey:uuid]) {
        IF(CBDescriptor*, descriptor, [self getDescriptor:peripheral service:serviceUuid characteristic:characteristicUuid descriptor:descriptorUuid]) {
            [peripheral readValueForDescriptor:descriptor];
            return YES;
        }
        LOGE("descriptor not found %s %s %s %s", [uuid UTF8String], [serviceUuid UTF8String], [characteristicUuid UTF8String], [descriptorUuid UTF8String]);
        return NO;
    }
    LOGE("peripheral not found %s", [uuid UTF8String]);
    return NO;
}

- (void)peripheral:(CBPeripheral *)peripheral didUpdateValueForDescriptor:(CBDescriptor *)descriptor error:(NSError *)error {
    std::string uuid = getUuid(peripheral);
    auto serviceUuid = [descriptor.characteristic.service.UUID.UUIDString UTF8String];
    auto characteristicUuid = [descriptor.characteristic.UUID.UUIDString UTF8String];
    auto descriptorUuid = [descriptor.UUID.UUIDString UTF8String];
    if(error) {
        LOGE("error %s %s %s %s %s", uuid.c_str(), serviceUuid, characteristicUuid, descriptorUuid, description(error));
    }
    const UInt8* bytes = (UInt8 *)[descriptor.value bytes];
    Data data;
    data.assign(bytes, bytes+[descriptor.value length]);
    IF(NSNumber*, handle, [self getDescriptorHandle:descriptor]) {
        emit.ReadHandle(uuid, [handle intValue], data);
    }
    emit.ReadValue(uuid, serviceUuid, characteristicUuid, descriptorUuid, data);
}

- (BOOL)writeValue:(NSString*) uuid service:(NSString*) serviceUuid characteristic:(NSString*) characteristicUuid descriptor:(NSString*) descriptorUuid data:(NSData*) data {
    IF(CBPeripheral *, peripheral, [self.peripherals objectForKey:uuid]) {
        IF(CBDescriptor*, descriptor, [self getDescriptor:peripheral service:serviceUuid characteristic:characteristicUuid descriptor:descriptorUuid]) {
            [peripheral writeValue:data forDescriptor:descriptor];
            return YES;
        }
        LOGE("descriptor not found %s %s %s %s", [uuid UTF8String], [serviceUuid UTF8String], [characteristicUuid UTF8String], [descriptorUuid UTF8String]);
        return NO;
    }
    LOGE("peripheral not found %s", [uuid UTF8String]);
    return NO;
}

- (void)peripheral:(CBPeripheral *)peripheral didWriteValueForDescriptor:(CBDescriptor *)descriptor error:(NSError *)error {
    std::string uuid = getUuid(peripheral);
    auto serviceUuid = [descriptor.characteristic.service.UUID.UUIDString UTF8String];
    auto characteristicUuid = [descriptor.characteristic.UUID.UUIDString UTF8String];
    auto descriptorUuid = [descriptor.UUID.UUIDString UTF8String];
    if(error) {
        LOGE("error %s %s %s %s %s", uuid.c_str(), serviceUuid, characteristicUuid, descriptorUuid, description(error));
    }
    IF(NSNumber*, handle, [self getDescriptorHandle:descriptor]) {
        emit.WriteHandle(uuid, [handle intValue]);
    }
    emit.WriteValue(uuid, serviceUuid, characteristicUuid, descriptorUuid);
}

- (BOOL)readHandle:(NSString*) uuid handle:(NSNumber*) handle {
    IF(CBPeripheral *, peripheral, [self.peripherals objectForKey:uuid]) {
        IF(CBDescriptor*, descriptor, [self getDescriptor:peripheral ByHandle:handle]) {
            [peripheral readValueForDescriptor:descriptor];
            return YES;
        }
        LOGE("descriptor not found %s handle %d", [uuid UTF8String], [handle intValue]);
        return NO;
    }
    LOGE("peripheral not found %s", [uuid UTF8String]);
    return NO;
}

- (BOOL)writeHandle:(NSString*) uuid handle:(NSNumber*) handle data:(NSData*) data  {
    IF(CBPeripheral *, peripheral, [self.peripherals objectForKey:uuid]) {
        IF(CBDescriptor*, descriptor, [self getDescriptor:peripheral ByHandle:handle]) {
            [peripheral writeValue:data forDescriptor:descriptor];
            return YES;
        }
        LOGE("descriptor not found %s handle %d", [uuid UTF8String], [handle intValue]);
        return NO;
    }
    LOGE("peripheral not found %s", [uuid UTF8String]);
    return NO;
}

#pragma mark - Accessor

-(CBService*)getService:(CBPeripheral*) peripheral service:(NSString*) serviceUuid {
    if(peripheral && peripheral.services) {
        for(CBService* service in peripheral.services) {
            if([service.UUID isEqualTo:[CBUUID UUIDWithString:serviceUuid]]) {
                return service;
            }
        }
    }
    return nil;
}

-(CBCharacteristic*)getCharacteristic:(CBPeripheral*) peripheral service:(NSString*) serviceUuid characteristic:(NSString*) characteristicUuid {
    CBService* service = [self getService:peripheral service:serviceUuid];
    if(service && service.characteristics) {
        for(CBCharacteristic* characteristic in service.characteristics) {
            if([characteristic.UUID isEqualTo:[CBUUID UUIDWithString:characteristicUuid]]) {
                return characteristic;
            }
        }
    }
    return nil;
}

-(CBDescriptor*)getDescriptor:(CBPeripheral*) peripheral service:(NSString*) serviceUuid characteristic:(NSString*) characteristicUuid descriptor:(NSString*) descriptorUuid {
    CBCharacteristic* characteristic = [self getCharacteristic:peripheral service:serviceUuid characteristic:characteristicUuid];
    if(characteristic && characteristic.descriptors) {
        for(CBDescriptor* descriptor in characteristic.descriptors) {
            if([descriptor.UUID isEqualTo:[CBUUID UUIDWithString:descriptorUuid]]) {
                return descriptor;
            }
        }
    }
    return nil;
}

-(NSNumber*)getDescriptorHandle:(CBDescriptor*) descriptor {
    // use KVC to get the private handle property
    id handle = [descriptor valueForKey:@"handle"];
    if([handle isKindOfClass:[NSNumber class]]) {
        return handle;
    }
    return nil;
}

-(CBDescriptor*)getDescriptor:(CBPeripheral*) peripheral ByHandle:(NSNumber*) handle {
    if(peripheral && peripheral.services) {
        for(CBService* service in peripheral.services) {
            if(service.characteristics) {
                for(CBCharacteristic* characteristic in service.characteristics) {
                    if(characteristic.descriptors) {
                        for(CBDescriptor* descriptor in characteristic.descriptors) {
                            if([handle isEqualTo:[self getDescriptorHandle:descriptor]]) {
                                return descriptor;
                            }
                        }
                    }
                }
            }
        }
    }
    return nil;
}

@end
