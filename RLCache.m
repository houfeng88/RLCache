//
//  RLCache.m
//  rlterm3
//
//  Created by Repeatlink-HouFeng on 16/5/18.
//  Copyright © 2016年 RepeatLink. All rights reserved.
//

#import "RLCache.h"


@interface NSDate(RLCacheDate)
-(BOOL)isInThePast;
@end

@implementation NSDate(RLCacheDate)
-(BOOL)isInThePast{
    return self.timeIntervalSinceNow < 0;
}
@end

@implementation RLCacheObject

-(instancetype)init{
    return nil;
}

-(instancetype)initWithValue:(id<NSCoding>) obj expiryDate:(NSDate *)date{
    self = [super init];
    self.value = obj;
    self.expiryDate = date;
    return self;
}
-(instancetype)initWithCoder:(NSCoder *)aDecoder{
    self.value = [aDecoder decodeObjectForKey:@"value"];
    self.expiryDate = [aDecoder decodeObjectForKey:@"expiryDate"];
    return self;
}
-(void)encodeWithCoder:(NSCoder *)aCoder{
    [aCoder encodeObject:self.value forKey:@"value"];
    [aCoder encodeObject:self.expiryDate forKey:@"expiryDate"];
}


@end


static id<RLCacheBackgroundTaskManager> RLCacheBackgroundTaskManager;
NSString *const RLDiskCachePrefix = @"com.repeatlink.rltem3.cache";
NSString *const RLDiskCacheSharedName = @"RLDiskCacheShared";


@interface RLDiskCache()
@property(assign)NSUInteger byteCount;
@property(strong,nonatomic) NSURL *cacheURL;
@property(strong,nonatomic)dispatch_queue_t queue;
@property(strong,nonatomic)NSMutableDictionary *dates;
@property(strong,nonatomic)NSMutableDictionary *sizes;
@end


#pragma mark - RLDiskCache
@implementation RLDiskCache

@synthesize willAddObjectBlock = _willAddObjectBlock;
@synthesize willRemoveObjectBlock = _willRemoveObjectBlock;
@synthesize willRemoveAllObjectsBlock = _willRemoveAllObjectsBlock;
@synthesize didAddObjectBlock = _didAddObjectBlock;
@synthesize didRemoveObjectBlock = _didRemoveObjectBlock;
@synthesize didRemoveAllObjectsBlock = _didRemoveAllObjectsBlock;
@synthesize byteLimit = _byteLimit;
@synthesize ageLimit = _ageLimit;

-(instancetype)initWithName:(NSString *)name{
    return [self initWithName:name rootPath:[NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject]];
}


-(instancetype)initWithName:(NSString *)name rootPath:(NSString *)rootPath{
    if(!name)return  nil;
    
    if(self = [super init]){
        _name =  [name copy];
        _queue = [RLDiskCache sharedQueue];
        
        _byteCount = 0;
        _byteLimit = 0;
        _ageLimit = 0.0;
        
        _dates = [[NSMutableDictionary alloc] init];
        _sizes = [[NSMutableDictionary alloc] init];
        NSString *pathComponent = [[NSString alloc] initWithFormat:@"%@.%@",RLDiskCachePrefix,_name];
        _cacheURL = [NSURL fileURLWithPathComponents:@[rootPath,pathComponent]];
        __weak RLDiskCache *weakSelf =  self;
        dispatch_async(_queue,^{
            RLDiskCache *strongSelf = weakSelf;
            [strongSelf createCacheDirectory];
            [strongSelf initializeDiskProperties];
        });
        
        
    }
    
    return self;
}

-(NSString *)description{
    return [NSString stringWithFormat:@"%@.%@.%p",RLDiskCachePrefix,_name,self];
}

+(instancetype)sharedCache{
    static id cache;
    static dispatch_once_t  predicate;
    dispatch_once(&predicate,^{
        cache = [[self alloc] initWithName:RLDiskCacheSharedName];
    });
    return cache;
}

+(dispatch_queue_t)sharedQueue{
    static dispatch_queue_t  queue;
    static dispatch_once_t  predicate;
    dispatch_once(&predicate,^{
        queue = dispatch_queue_create([RLDiskCachePrefix UTF8String], DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

-(NSURL *)encodedFileURLForKey:(NSString *)key{
    if(![key length]){
        return  nil;
    }
    return [_cacheURL URLByAppendingPathComponent:[self encodeString:key]];
}


- (NSString *)keyForEncodedFileURL:(NSURL *)url
{
    NSString *fileName = [url lastPathComponent];
    if (!fileName)
        return nil;
    
    return [self decodedString:fileName];
}


-(NSString *)encodeString:(NSString *)string{
    if (![string length])
        return @"";
    CFStringRef static const charsToEscape = CFSTR(".:/");
    CFStringRef escapedString =  CFURLCreateStringByAddingPercentEscapes(kCFAllocatorDefault,
                                                                         (__bridge CFStringRef)string,
                                                                         NULL,
                                                                         charsToEscape,
                                                                         kCFStringEncodingUTF8);
    return (__bridge_transfer NSString *)escapedString;
    
}

- (NSString *)decodedString:(NSString *)string
{
    if (![string length])
        return @"";
    
    CFStringRef unescapedString = CFURLCreateStringByReplacingPercentEscapesUsingEncoding(kCFAllocatorDefault,
                                                                                          (__bridge CFStringRef)string,
                                                                                          CFSTR(""),
                                                                                          kCFStringEncodingUTF8);
    return (__bridge_transfer NSString *)unescapedString;
}

+(dispatch_queue_t)sharedTrashQueue{
    static dispatch_queue_t trashQueue;
    static dispatch_once_t predicate;
    dispatch_once(&predicate, ^{
        NSString *queueName = [NSString stringWithFormat:@"%@.trash",RLDiskCachePrefix];
        trashQueue = dispatch_queue_create([queueName UTF8String], DISPATCH_QUEUE_SERIAL);
        //修改队列优先级
        dispatch_set_target_queue(trashQueue, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0));
    });
    return trashQueue;
}


+(NSURL *)sharedTrashURL{
    static NSURL *sharedTrashURL;
    static dispatch_once_t predicate;
    dispatch_once(&predicate,^{
        sharedTrashURL = [[[NSURL alloc] initFileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:RLDiskCachePrefix isDirectory:YES];
        if(![[NSFileManager defaultManager] fileExistsAtPath:[sharedTrashURL path]]){
            NSError *error = nil;
            [[NSFileManager defaultManager] createDirectoryAtURL:sharedTrashURL withIntermediateDirectories:YES attributes:nil error:&error];
            NSLog(@"%@",error);
        }
    });
    return sharedTrashURL;
}


+(BOOL)moveItemAtURLToTrash:(NSURL *)itemURL{
    if(![[NSFileManager defaultManager] fileExistsAtPath:[itemURL path]]){
        return NO;
    }
    NSError *error = nil;
    NSString *uniqueString = [[NSProcessInfo processInfo] globallyUniqueString];
    NSURL *uniqueTrashURL = [[RLDiskCache sharedTrashURL] URLByAppendingPathComponent:uniqueString];
    BOOL moved = [[NSFileManager defaultManager] moveItemAtURL:itemURL toURL:uniqueTrashURL error:&error];
    NSLog(@"%@",error);
    return moved;
}


+(void)emptyTrash{
    UIBackgroundTaskIdentifier taskID = [RLCacheBackgroundTaskManager beginBackgroundTask];
    dispatch_async([self sharedTrashQueue], ^{
        NSError *error = nil;
        NSArray *trashedItems = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:[self sharedTrashURL]
                                                              includingPropertiesForKeys:nil
                                                                               options:0
                                                                                   error:&error];
        
        
         NSLog(@"%@",error);
        
        for(NSURL *trashedItemURL in trashedItems){
            NSError *error = nil;
            [[NSFileManager defaultManager] removeItemAtURL:trashedItemURL error:&error];
            NSLog(@"%@",error);
            
        }
        
        [RLCacheBackgroundTaskManager endBackgroundTask:taskID];
    });
}
-(BOOL)createCacheDirectory{
    if([[NSFileManager defaultManager] fileExistsAtPath:[_cacheURL path]]){
        return NO;
    }
    NSError *error = nil;
    BOOL success = [[NSFileManager defaultManager] createDirectoryAtURL:_cacheURL withIntermediateDirectories:YES attributes:nil error:&error];
    return success;
}

-(void)initializeDiskProperties{
    NSUInteger byteCount = 0;
    NSArray *keys = @[NSURLContentModificationDateKey,NSURLTotalFileSizeKey];
    NSError *error = nil;
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:_cacheURL includingPropertiesForKeys:keys options:NSDirectoryEnumerationSkipsHiddenFiles error:&error];
     NSLog(@"%@",error);
    
    for(NSURL *fileURL in files){
        NSString *key = [self keyForEncodedFileURL:fileURL];
        error = nil;
        NSDictionary *dictionary = [fileURL resourceValuesForKeys:keys error:&error];
        NSDate *date = [dictionary objectForKey:NSURLContentModificationDateKey];
        if(date && key){
            [_dates setObject:date forKey:key];
        }
        
        NSNumber *fileSize = [dictionary objectForKey:NSURLTotalFileAllocatedSizeKey];
        if(fileSize){
            [_sizes setObject:fileSize forKey:key];
            byteCount += [fileSize unsignedIntegerValue];
        }
    }
    if(byteCount > 0){
        self.byteCount = byteCount;
    }
    
    
    
}

-(BOOL)setFileModificationDate:(NSDate *)date forURL:(NSURL *)fileURL{
    if(!date || !fileURL){
        return NO;
    }
    NSError *error = nil;
    BOOL success = [[NSFileManager defaultManager] setAttributes:@{NSFileModificationDate:date} ofItemAtPath:[fileURL path] error:&error];
    if(success){
        NSString *key = [self keyForEncodedFileURL:fileURL];
        if(key){
            [_dates setObject:date forKey:key];
        }
    }
    return success;
    
}

-(BOOL)removeFileAndExecuteBlocksForKey:(NSString *)key{
    NSURL *fileURL = [self encodedFileURLForKey:key];
    if(!fileURL || ![[NSFileManager defaultManager] fileExistsAtPath:[fileURL path]]){
        return NO;
    }
    if(_willRemoveObjectBlock){
        _willRemoveObjectBlock(self,key,nil,fileURL);
    }
    BOOL trashed = [RLDiskCache moveItemAtURLToTrash:fileURL];
    if(!trashed)
        return  NO;
    [RLDiskCache emptyTrash];
    
    NSNumber *byteSize = [_sizes objectForKey:key];
    if(byteSize){
        self.byteCount = _byteCount - [byteSize unsignedIntegerValue];
    }
    [_sizes removeObjectForKey:key];
    [_dates removeObjectForKey:key];
    
    if(_didRemoveObjectBlock){
        _didRemoveObjectBlock(self,key,nil,fileURL);
    }
    return  YES;
}



-(void)trimDiskToSize:(NSUInteger)trimByteCount{
    if(_byteCount <= trimByteCount){
        return;
    }
    NSArray *keysSortedBySize = [_sizes keysSortedByValueUsingSelector:@selector(compare:)];
    for(NSString *key in [keysSortedBySize reverseObjectEnumerator]){
        [self removeFileAndExecuteBlocksForKey:key];
        if(_byteCount <= trimByteCount){
            break;
        }
    }
}




-(void)trimDiskToSizeByDate:(NSUInteger)trimByteCount{
    if(_byteCount <= trimByteCount){
        return;
    }
    NSArray *keysSortedByDate = [_dates keysSortedByValueUsingSelector:@selector(compare:)];
    
    for (NSString *key in keysSortedByDate) { // oldest objects first
        [self removeFileAndExecuteBlocksForKey:key];
        
        if (_byteCount <= trimByteCount)
            break;
    }
    
}




-(void)trimDiskToDate:(NSDate *)trimDate{
    NSArray *keysSortedByDate = [_dates keysSortedByValueUsingSelector:@selector(compare:)];
    for(NSString *key in  keysSortedByDate){
        NSDate *accessDate = [_dates objectForKey:key];
        if(!accessDate){
            continue;
        }
        if([accessDate compare:trimDate] == NSOrderedAscending){
            [self removeFileAndExecuteBlocksForKey:key];
        }else{
            break;
        }
    }
    
}



-(void)trimToAgeLimitRecursively{
    if(_ageLimit == 0.0){
        return;
    }
    
    NSDate *date = [[NSDate alloc] initWithTimeIntervalSinceNow:-_ageLimit];
    [self trimDiskToDate:date];
    __weak RLDiskCache *weakSelf = self;
    dispatch_time_t time = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(_ageLimit * NSEC_PER_SEC));
    dispatch_after(time, _queue, ^(void) {
        RLDiskCache *strongSelf = weakSelf;
        [strongSelf trimToAgeLimitRecursively];
    });

}


-(void)objectForKey:(NSString *)key block:(RLDiskCacheObjectBlock)block{
    NSDate *now = [[NSDate alloc] init];
    if(!key || !block){
        return;
    }
    __weak  RLDiskCache *weakSelf = self;
    
    dispatch_async(_queue,^{
        RLDiskCache *strongSelf = weakSelf;
        NSURL *fileURL = [strongSelf encodedFileURLForKey:key];
        id <NSCoding> object = nil;
        if([[NSFileManager defaultManager] fileExistsAtPath:[fileURL path]]){
            @try{
                object = [NSKeyedUnarchiver unarchiveObjectWithFile:[fileURL path]];
            }@catch(NSException *exception){
                NSError *error = nil;
                [[NSFileManager defaultManager] removeItemAtPath:[fileURL path] error:&error];
            }
            [strongSelf setFileModificationDate:now forURL:fileURL];
        }
        
        if(block){
            block(strongSelf,key,object,fileURL);
        }
    });
}

- (void)fileURLForKey:(NSString *)key block:(RLDiskCacheObjectBlock)block
{
    NSDate *now = [[NSDate alloc] init];
    
    if (!key || !block)
        return;
    
    __weak RLDiskCache *weakSelf = self;
    
    dispatch_async(_queue, ^{
        RLDiskCache *strongSelf = weakSelf;
        if (!strongSelf)
            return;
        
        NSURL *fileURL = [strongSelf encodedFileURLForKey:key];
        
        if ([[NSFileManager defaultManager] fileExistsAtPath:[fileURL path]]) {
            [strongSelf setFileModificationDate:now forURL:fileURL];
        } else {
            fileURL = nil;
        }
        
        block(strongSelf, key, nil, fileURL);
    });
}

-(void)setObject:(id<NSCoding>)object forKey:(NSString *)key block:(RLDiskCacheObjectBlock)block{
    NSDate *now = [[NSDate alloc] init];
    if (!key || !object)
        return;
    
     UIBackgroundTaskIdentifier taskID = [RLCacheBackgroundTaskManager beginBackgroundTask];
    
    __weak RLDiskCache *weakSelf = self;
    
    dispatch_async(_queue, ^{
       
        RLDiskCache *strongSelf = weakSelf;
        
        NSURL *fileURL = [strongSelf encodedFileURLForKey:key];
        if (strongSelf->_willAddObjectBlock)
            strongSelf->_willAddObjectBlock(strongSelf, key, object, fileURL);
        
        BOOL written = [NSKeyedArchiver archiveRootObject:object toFile:[fileURL path]];
        if(written){
            [strongSelf setFileModificationDate:now forURL:fileURL];
            NSError *error = nil;
            NSDictionary *values = [fileURL resourceValuesForKeys:@[ NSURLTotalFileAllocatedSizeKey ] error:&error];
            NSNumber *diskFileSize = [values objectForKey:NSURLTotalFileAllocatedSizeKey];
            if(diskFileSize){
                 NSNumber *oldEntry = [strongSelf->_sizes objectForKey:key];
                if ([oldEntry isKindOfClass:[NSNumber class]]){
                    strongSelf.byteCount = strongSelf->_byteCount - [oldEntry unsignedIntegerValue];
                }
                [strongSelf->_sizes setObject:diskFileSize forKey:key];
                strongSelf.byteCount = strongSelf->_byteCount + [diskFileSize unsignedIntegerValue];
            }
            
            if (strongSelf->_byteLimit > 0 && strongSelf->_byteCount > strongSelf->_byteLimit)
                [strongSelf trimToSizeByDate:strongSelf->_byteLimit block:nil];
        }else{
            fileURL = nil;
        }
        
        if(strongSelf-> _didAddObjectBlock){
             strongSelf->_didAddObjectBlock(strongSelf, key, object, written ? fileURL : nil);
        }
        
        if (block)
            block(strongSelf, key, object, fileURL);
        [RLCacheBackgroundTaskManager endBackgroundTask:taskID];
    });
    
    
}

-(void)removeObjectForKey:(NSString *)key block:(RLDiskCacheObjectBlock)block{
    if(!key){
        return;
    }
    UIBackgroundTaskIdentifier taskID = [RLCacheBackgroundTaskManager beginBackgroundTask];
    __weak RLDiskCache *weakSelf = self;
    dispatch_async(_queue,^{
        RLDiskCache *strongSelf = weakSelf;
        NSURL *fileURL = [strongSelf encodedFileURLForKey:key];
        [strongSelf removeFileAndExecuteBlocksForKey:key];
        if (block)
            block(strongSelf, key, nil, fileURL);
        
        [RLCacheBackgroundTaskManager endBackgroundTask:taskID];
    });
    
}


-(void)trimToSize:(NSUInteger)trimByteCount block:(RLDiskCacheBlock)block{
    if(trimByteCount == 0){
        [self removeAllObjects:block];
        return;
    }
    UIBackgroundTaskIdentifier taskID = [RLCacheBackgroundTaskManager beginBackgroundTask];
    __weak  RLDiskCache *weakSelf = self;
    
    dispatch_async(_queue,^{
        RLDiskCache *strongSelf = weakSelf;
        if(!strongSelf){
            [RLCacheBackgroundTaskManager endBackgroundTask:taskID];
            return ;
        }
        
        if(block){
            block(strongSelf);
        }
        
         [RLCacheBackgroundTaskManager endBackgroundTask:taskID];
    });
}


-(void)trimToDate:(NSDate *)trimDate  block:(RLDiskCacheBlock)block{
    if(!trimDate){
        return;
    }
    
    if([trimDate isEqualToDate:[NSDate distantPast]]){
        [self removeAllObjects:block];
        return;
    }
    
    UIBackgroundTaskIdentifier *taskID = [RLCacheBackgroundTaskManager beginBackgroundTask];
    __weak  RLDiskCache *weakSelf = self;
    dispatch_async(_queue, ^{
        RLDiskCache *strongSelf = weakSelf;
        if(!strongSelf){
            [RLCacheBackgroundTaskManager endBackgroundTask:taskID];
            return ;
        }
        [strongSelf trimDiskToDate:trimDate];
        if(block){
            block(strongSelf);
        }
        
        [RLCacheBackgroundTaskManager endBackgroundTask:taskID];
    });
    
}


- (void)trimToSizeByDate:(NSUInteger)trimByteCount block:(RLDiskCacheBlock)block
{
    if (trimByteCount == 0) {
        [self removeAllObjects:block];
        return;
    }
    
    UIBackgroundTaskIdentifier taskID = [RLCacheBackgroundTaskManager beginBackgroundTask];
    
    __weak RLDiskCache *weakSelf = self;
    
    dispatch_async(_queue, ^{
        RLDiskCache *strongSelf = weakSelf;
        if (!strongSelf) {
            [RLCacheBackgroundTaskManager endBackgroundTask:taskID];
            return;
        }
        
        [strongSelf trimDiskToSizeByDate:trimByteCount];
        
        if (block)
            block(strongSelf);
        
        [RLCacheBackgroundTaskManager endBackgroundTask:taskID];
    });
}



- (void)removeAllObjects:(RLDiskCacheBlock)block
{
    UIBackgroundTaskIdentifier taskID = [RLCacheBackgroundTaskManager beginBackgroundTask];
    
    __weak RLDiskCache *weakSelf = self;
    
    dispatch_async(_queue, ^{
        RLDiskCache *strongSelf = weakSelf;
        if (!strongSelf) {
            [RLCacheBackgroundTaskManager endBackgroundTask:taskID];
            return;
        }
        
        if (strongSelf->_willRemoveAllObjectsBlock)
            strongSelf->_willRemoveAllObjectsBlock(strongSelf);
        
        [RLDiskCache moveItemAtURLToTrash:strongSelf->_cacheURL];
        [RLDiskCache emptyTrash];
        
        [strongSelf createCacheDirectory];
        
        [strongSelf->_dates removeAllObjects];
        [strongSelf->_sizes removeAllObjects];
        strongSelf.byteCount = 0; // atomic
        
        if (strongSelf->_didRemoveAllObjectsBlock)
            strongSelf->_didRemoveAllObjectsBlock(strongSelf);
        
        if (block)
            block(strongSelf);
        
        [RLCacheBackgroundTaskManager endBackgroundTask:taskID];
    });
}





-(void)enumerateObjectsWithBlock:(RLDiskCacheObjectBlock)block completionBlock:(RLDiskCacheBlock)completionBlock{
    if(!block){
        return;
    }
    
    UIBackgroundTaskIdentifier taskID = [RLCacheBackgroundTaskManager beginBackgroundTask];
     __weak RLDiskCache *weakSelf = self;
    dispatch_async(_queue, ^{
        RLDiskCache *strongSelf = weakSelf;
        if (!strongSelf) {
            [RLCacheBackgroundTaskManager endBackgroundTask:taskID];
            return;
        }
        
        NSArray *keysSortedByDate = [strongSelf->_dates keysSortedByValueUsingSelector:@selector(compare:)];
        
        for (NSString *key in keysSortedByDate) {
            NSURL *fileURL = [strongSelf encodedFileURLForKey:key];
            block(strongSelf, key, nil, fileURL);
        }
        
        if (completionBlock)
            completionBlock(strongSelf);
        
        [RLCacheBackgroundTaskManager endBackgroundTask:taskID];
    });

    
}



-(id<NSCoding>)objectForKey:(NSString *)key{
    if(!key)
        return nil;
    __block id <NSCoding> objectForKey = nil;
    dispatch_semaphore_t  semaphore = dispatch_semaphore_create(0);
    [self objectForKey:key block:^(RLDiskCache *cache, NSString *key, id<NSCoding> object, NSURL *fileURL) {
        objectForKey = object;
        dispatch_semaphore_signal(semaphore);
    }];
    
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    return objectForKey;
}



- (NSURL *)fileURLForKey:(NSString *)key
{
    if (!key)
        return nil;
    
    __block NSURL *fileURLForKey = nil;
    
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    
    [self fileURLForKey:key block:^(RLDiskCache *cache, NSString *key, id <NSCoding> object, NSURL *fileURL) {
        fileURLForKey = fileURL;
        dispatch_semaphore_signal(semaphore);
    }];
    
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    
#if !OS_OBJECT_USE_OBJC
    dispatch_release(semaphore);
#endif
    
    return fileURLForKey;
}

- (void)setObject:(id <NSCoding>)object forKey:(NSString *)key
{
    if (!object || !key)
        return;
    
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    
    [self setObject:object forKey:key block:^(RLDiskCache *cache, NSString *key, id <NSCoding> object, NSURL *fileURL) {
        dispatch_semaphore_signal(semaphore);
    }];
    
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    
#if !OS_OBJECT_USE_OBJC
    dispatch_release(semaphore);
#endif
}

- (void)removeObjectForKey:(NSString *)key
{
    if (!key)
        return;
    
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    
    [self removeObjectForKey:key block:^(RLDiskCache *cache, NSString *key, id <NSCoding> object, NSURL *fileURL) {
        dispatch_semaphore_signal(semaphore);
    }];
    
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    
#if !OS_OBJECT_USE_OBJC
    dispatch_release(semaphore);
#endif
}

- (void)trimToSize:(NSUInteger)byteCount
{
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    
    [self trimToSize:byteCount block:^(RLDiskCache *cache) {
        dispatch_semaphore_signal(semaphore);
    }];
    
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    
#if !OS_OBJECT_USE_OBJC
    dispatch_release(semaphore);
#endif
}

- (void)trimToDate:(NSDate *)date
{
    if (!date)
        return;
    
    if ([date isEqualToDate:[NSDate distantPast]]) {
        [self removeAllObjects];
        return;
    }
    
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    
    [self trimToDate:date block:^(RLDiskCache *cache) {
        dispatch_semaphore_signal(semaphore);
    }];
    
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    
#if !OS_OBJECT_USE_OBJC
    dispatch_release(semaphore);
#endif
}

- (void)trimToSizeByDate:(NSUInteger)byteCount
{
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    
    [self trimToSizeByDate:byteCount block:^(RLDiskCache *cache) {
        dispatch_semaphore_signal(semaphore);
    }];
    
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    
#if !OS_OBJECT_USE_OBJC
    dispatch_release(semaphore);
#endif
}

- (void)removeAllObjects
{
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    
    [self removeAllObjects:^(RLDiskCache *cache) {
        dispatch_semaphore_signal(semaphore);
    }];
    
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    
#if !OS_OBJECT_USE_OBJC
    dispatch_release(semaphore);
#endif
}

- (void)enumerateObjectsWithBlock:(RLDiskCacheObjectBlock)block
{
    if (!block)
        return;
    
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    
    [self enumerateObjectsWithBlock:block completionBlock:^(RLDiskCache *cache) {
        dispatch_semaphore_signal(semaphore);
    }];
    
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    
#if !OS_OBJECT_USE_OBJC
    dispatch_release(semaphore);
#endif
}

//线程安全
- (RLDiskCacheObjectBlock)willAddObjectBlock
{
    __block RLDiskCacheObjectBlock block = nil;
    
    dispatch_sync(_queue, ^{
        block = _willAddObjectBlock;
    });
    
    return block;
}

- (void)setWillAddObjectBlock:(RLDiskCacheObjectBlock)block
{
    __weak RLDiskCache *weakSelf = self;
    
    dispatch_async(_queue, ^{
        RLDiskCache *strongSelf = weakSelf;
        if (!strongSelf)
            return;
        
        strongSelf->_willAddObjectBlock = [block copy];
    });
}

- (RLDiskCacheObjectBlock)willRemoveObjectBlock
{
    __block RLDiskCacheObjectBlock block = nil;
    
    dispatch_sync(_queue, ^{
        block = _willRemoveObjectBlock;
    });
    
    return block;
}

- (void)setWillRemoveObjectBlock:(RLDiskCacheObjectBlock)block
{
    __weak RLDiskCache *weakSelf = self;
    
    dispatch_async(_queue, ^{
        RLDiskCache *strongSelf = weakSelf;
        if (!strongSelf)
            return;
        
        strongSelf->_willRemoveObjectBlock = [block copy];
    });
}

- (RLDiskCacheBlock)willRemoveAllObjectsBlock
{
    __block RLDiskCacheBlock block = nil;
    
    dispatch_sync(_queue, ^{
        block = _willRemoveAllObjectsBlock;
    });
    
    return block;
}

- (void)setWillRemoveAllObjectsBlock:(RLDiskCacheBlock)block
{
    __weak RLDiskCache *weakSelf = self;
    
    dispatch_async(_queue, ^{
        RLDiskCache *strongSelf = weakSelf;
        if (!strongSelf)
            return;
        
        strongSelf->_willRemoveAllObjectsBlock = [block copy];
    });
}

- (RLDiskCacheObjectBlock)didAddObjectBlock
{
    __block RLDiskCacheObjectBlock block = nil;
    
    dispatch_sync(_queue, ^{
        block = _didAddObjectBlock;
    });
    
    return block;
}

- (void)setDidAddObjectBlock:(RLDiskCacheObjectBlock)block
{
    __weak RLDiskCache *weakSelf = self;
    
    dispatch_async(_queue, ^{
        RLDiskCache *strongSelf = weakSelf;
        if (!strongSelf)
            return;
        
        strongSelf->_didAddObjectBlock = [block copy];
    });
}

- (RLDiskCacheObjectBlock)didRemoveObjectBlock
{
    __block RLDiskCacheObjectBlock block = nil;
    
    dispatch_sync(_queue, ^{
        block = _didRemoveObjectBlock;
    });
    
    return block;
}

- (void)setDidRemoveObjectBlock:(RLDiskCacheObjectBlock)block
{
    __weak RLDiskCache *weakSelf = self;
    
    dispatch_async(_queue, ^{
        RLDiskCache *strongSelf = weakSelf;
        if (!strongSelf)
            return;
        
        strongSelf->_didRemoveObjectBlock = [block copy];
    });
}

- (RLDiskCacheBlock)didRemoveAllObjectsBlock
{
    __block RLDiskCacheBlock block = nil;
    
    dispatch_sync(_queue, ^{
        block = _didRemoveAllObjectsBlock;
    });
    
    return block;
}

- (void)setDidRemoveAllObjectsBlock:(RLDiskCacheBlock)block
{
    __weak RLDiskCache *weakSelf = self;
    
    dispatch_async(_queue, ^{
        RLDiskCache *strongSelf = weakSelf;
        if (!strongSelf)
            return;
        
        strongSelf->_didRemoveAllObjectsBlock = [block copy];
    });
}

- (NSUInteger)byteLimit
{
    __block NSUInteger byteLimit = 0;
    
    dispatch_sync(_queue, ^{
        byteLimit = _byteLimit;
    });
    
    return byteLimit;
}

- (void)setByteLimit:(NSUInteger)byteLimit
{
    __weak RLDiskCache *weakSelf = self;
    
    dispatch_barrier_async(_queue, ^{
        RLDiskCache *strongSelf = weakSelf;
        if (!strongSelf)
            return;
        
        strongSelf->_byteLimit = byteLimit;
        
        if (byteLimit > 0)
            [strongSelf trimDiskToSizeByDate:byteLimit];
    });
}

- (NSTimeInterval)ageLimit
{
    __block NSTimeInterval ageLimit = 0.0;
    
    dispatch_sync(_queue, ^{
        ageLimit = _ageLimit;
    });
    
    return ageLimit;
}

- (void)setAgeLimit:(NSTimeInterval)ageLimit
{
    __weak RLDiskCache *weakSelf = self;
    
    dispatch_barrier_async(_queue, ^{
        RLDiskCache *strongSelf = weakSelf;
        if (!strongSelf)
            return;
        
        strongSelf->_ageLimit = ageLimit;
        
        [strongSelf trimToAgeLimitRecursively];
    });
}



+ (void)setBackgroundTaskManager:(id <RLCacheBackgroundTaskManager>)backgroundTaskManager {
    RLCacheBackgroundTaskManager = backgroundTaskManager;
}
@end




//////////////////////////RLMemoryCache//////////////////

NSString * const RLMemoryCachePrefix = @"com.repeatlink.rlterm3.RLMemoryCache";

#pragma mark - RLMemoryCache
@interface RLMemoryCache()
@property (strong, nonatomic) dispatch_queue_t queue;
@property (strong, nonatomic) NSMutableDictionary *dictionary;
@property (strong, nonatomic) NSMutableDictionary *dates;
@property (strong, nonatomic) NSMutableDictionary *costs;
@end

@implementation RLMemoryCache
@synthesize ageLimit = _ageLimit;
@synthesize costLimit = _costLimit;
@synthesize totalCost = _totalCost;
@synthesize willAddObjectBlock = _willAddObjectBlock;
@synthesize willRemoveObjectBlock = _willRemoveObjectBlock;
@synthesize willRemoveAllObjectsBlock = _willRemoveAllObjectsBlock;
@synthesize didAddObjectBlock = _didAddObjectBlock;
@synthesize didRemoveObjectBlock = _didRemoveObjectBlock;
@synthesize didRemoveAllObjectsBlock = _didRemoveAllObjectsBlock;
@synthesize didReceiveMemoryWarningBlock = _didReceiveMemoryWarningBlock;
@synthesize didEnterBackgroundBlock = _didEnterBackgroundBlock;


-(void)dealloc{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (id)init
{
    if (self = [super init]) {
        NSString *queueName = [[NSString alloc] initWithFormat:@"%@.%p", RLMemoryCachePrefix, self];
        _queue = dispatch_queue_create([queueName UTF8String], DISPATCH_QUEUE_CONCURRENT);
        
        _dictionary = [[NSMutableDictionary alloc] init];
        _dates = [[NSMutableDictionary alloc] init];
        _costs = [[NSMutableDictionary alloc] init];
        
        _willAddObjectBlock = nil;
        _willRemoveObjectBlock = nil;
        _willRemoveAllObjectsBlock = nil;
        
        _didAddObjectBlock = nil;
        _didRemoveObjectBlock = nil;
        _didRemoveAllObjectsBlock = nil;
        
        _didReceiveMemoryWarningBlock = nil;
        _didEnterBackgroundBlock = nil;
        
        _ageLimit = 0.0;
        _costLimit = 0;
        _totalCost = 0;
        
        _removeAllObjectsOnMemoryWarning = YES;
        _removeAllObjectsOnEnteringBackground = YES;
        
#if __IPHONE_OS_VERSION_MIN_REQUIRED >= __IPHONE_4_0
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleMemoryWarning)
                                                     name:UIApplicationDidReceiveMemoryWarningNotification
                                                   object:nil];
        
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleApplicationBackgrounding)
                                                     name:UIApplicationDidEnterBackgroundNotification
                                                   object:nil];
#endif
    }
    return self;
}



+(instancetype)sharedCache{
    static id cache;
    static dispatch_once_t predicate;
    
    dispatch_once(&predicate, ^{
        cache = [[self alloc] init];
    });
    
    return cache;
}

- (void)handleMemoryWarning
{
#if __IPHONE_OS_VERSION_MIN_REQUIRED >= __IPHONE_4_0
    
    if (self.removeAllObjectsOnMemoryWarning)
        [self removeAllObjects:nil];
    
    __weak RLMemoryCache *weakSelf = self;
    
    dispatch_async(_queue, ^{
        RLMemoryCache *strongSelf = weakSelf;
        if (!strongSelf)
            return;
        
        if (strongSelf->_didReceiveMemoryWarningBlock)
            strongSelf->_didReceiveMemoryWarningBlock(strongSelf);
    });
    
#endif
}

- (void)handleApplicationBackgrounding
{
#if __IPHONE_OS_VERSION_MIN_REQUIRED >= __IPHONE_4_0
    
    if (self.removeAllObjectsOnEnteringBackground)
        [self removeAllObjects:nil];
    
    __weak RLMemoryCache *weakSelf = self;
    
    dispatch_async(_queue, ^{
        RLMemoryCache *strongSelf = weakSelf;
        if (!strongSelf)
            return;
        
        if (strongSelf->_didEnterBackgroundBlock)
            strongSelf->_didEnterBackgroundBlock(strongSelf);
    });
    
#endif
}



- (void)removeObjectAndExecuteBlocksForKey:(NSString *)key
{
    id object = [_dictionary objectForKey:key];
    NSNumber *cost = [_costs objectForKey:key];
    
    if (_willRemoveObjectBlock)
        _willRemoveObjectBlock(self, key, object);
    
    if (cost)
        _totalCost -= [cost unsignedIntegerValue];
    
    [_dictionary removeObjectForKey:key];
    [_dates removeObjectForKey:key];
    [_costs removeObjectForKey:key];
    
    if (_didRemoveObjectBlock)
        _didRemoveObjectBlock(self, key, nil);
}



- (void)trimMemoryToDate:(NSDate *)trimDate
{
    NSArray *keysSortedByDate = [_dates keysSortedByValueUsingSelector:@selector(compare:)];
    
    for (NSString *key in keysSortedByDate) { // oldest objects first
        NSDate *accessDate = [_dates objectForKey:key];
        if (!accessDate)
            continue;
        
        if ([accessDate compare:trimDate] == NSOrderedAscending) { // older than trim date
            [self removeObjectAndExecuteBlocksForKey:key];
        } else {
            break;
        }
    }
}


- (void)trimToCostLimit:(NSUInteger)limit
{
    if (_totalCost <= limit)
        return;
    
    NSArray *keysSortedByCost = [_costs keysSortedByValueUsingSelector:@selector(compare:)];
    
    for (NSString *key in [keysSortedByCost reverseObjectEnumerator]) { // costliest objects first
        [self removeObjectAndExecuteBlocksForKey:key];
        
        if (_totalCost <= limit)
            break;
    }
}
- (void)trimToCostLimitByDate:(NSUInteger)limit
{
    if (_totalCost <= limit)
        return;
    
    NSArray *keysSortedByDate = [_dates keysSortedByValueUsingSelector:@selector(compare:)];
    
    for (NSString *key in keysSortedByDate) { // oldest objects first
        [self removeObjectAndExecuteBlocksForKey:key];
        
        if (_totalCost <= limit)
            break;
    }
}
- (void)trimToAgeLimitRecursively
{
    if (_ageLimit == 0.0)
        return;
    
    NSDate *date = [[NSDate alloc] initWithTimeIntervalSinceNow:-_ageLimit];
    [self trimMemoryToDate:date];
    
    __weak RLMemoryCache *weakSelf = self;
    
    dispatch_time_t time = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(_ageLimit * NSEC_PER_SEC));
    dispatch_after(time, _queue, ^(void){
        RLMemoryCache *strongSelf = weakSelf;
        if (!strongSelf)
            return;
        
        __weak RLMemoryCache *weakSelf = strongSelf;
        
        dispatch_barrier_async(strongSelf->_queue, ^{
            RLMemoryCache *strongSelf = weakSelf;
            [strongSelf trimToAgeLimitRecursively];
        });
    });
}


- (void)objectForKey:(NSString *)key block:(RLMemoryCacheObjectBlock)block
{
    NSDate *now = [[NSDate alloc] init];
    
    if (!key || !block)
        return;
    
    __weak RLMemoryCache *weakSelf = self;
    
    dispatch_async(_queue, ^{
        RLMemoryCache *strongSelf = weakSelf;
        if (!strongSelf)
            return;
        
        id object = [strongSelf->_dictionary objectForKey:key];
        
        if (object) {
            __weak RLMemoryCache *weakSelf = strongSelf;
            dispatch_barrier_async(strongSelf->_queue, ^{
                RLMemoryCache *strongSelf = weakSelf;
                if (strongSelf)
                    [strongSelf->_dates setObject:now forKey:key];
            });
        }
        if(block)
            block(strongSelf, key, object);
    });
}


- (void)setObject:(id)object forKey:(NSString *)key block:(RLMemoryCacheObjectBlock)block
{
    [self setObject:object forKey:key withCost:0 block:block];
}




- (void)setObject:(id)object forKey:(NSString *)key withCost:(NSUInteger)cost block:(RLMemoryCacheObjectBlock)block
{
    NSDate *now = [[NSDate alloc] init];
    
    if (!key || !object)
        return;
    
    __weak RLMemoryCache *weakSelf = self;
    
    dispatch_barrier_async(_queue, ^{
        RLMemoryCache *strongSelf = weakSelf;
        if (!strongSelf)
            return;
        
        if (strongSelf->_willAddObjectBlock)
            strongSelf->_willAddObjectBlock(strongSelf, key, object);
        
        [strongSelf->_dictionary setObject:object forKey:key];
        [strongSelf->_dates setObject:now forKey:key];
        [strongSelf->_costs setObject:@(cost) forKey:key];
        
        _totalCost += cost;
        
        if (strongSelf->_didAddObjectBlock)
            strongSelf->_didAddObjectBlock(strongSelf, key, object);
        
        if (strongSelf->_costLimit > 0)
            [strongSelf trimToCostByDate:strongSelf->_costLimit block:nil];
        
        if (block) {
            __weak RLMemoryCache *weakSelf = strongSelf;
            dispatch_async(strongSelf->_queue, ^{
                RLMemoryCache *strongSelf = weakSelf;
                if (strongSelf)
                    block(strongSelf, key, object);
            });
        }
    });
}

- (void)removeObjectForKey:(NSString *)key block:(RLMemoryCacheObjectBlock)block
{
    if (!key)
        return;
    
    __weak RLMemoryCache *weakSelf = self;
    
    dispatch_barrier_async(_queue, ^{
        RLMemoryCache *strongSelf = weakSelf;
        if (!strongSelf)
            return;
        
        [strongSelf removeObjectAndExecuteBlocksForKey:key];
        
        if (block) {
            __weak RLMemoryCache *weakSelf = strongSelf;
            dispatch_async(strongSelf->_queue, ^{
                RLMemoryCache *strongSelf = weakSelf;
                if (strongSelf)
                    block(strongSelf, key, nil);
            });
        }
    });
}

- (void)trimToDate:(NSDate *)trimDate block:(RLMemoryCacheBlock)block
{
    if (!trimDate)
        return;
    
    if ([trimDate isEqualToDate:[NSDate distantPast]]) {
        [self removeAllObjects:block];
        return;
    }
    
    __weak RLMemoryCache *weakSelf = self;
    
    dispatch_barrier_async(_queue, ^{
        RLMemoryCache *strongSelf = weakSelf;
        if (!strongSelf)
            return;
        
        [strongSelf trimMemoryToDate:trimDate];
        
        if (block) {
            __weak RLMemoryCache *weakSelf = strongSelf;
            dispatch_async(strongSelf->_queue, ^{
                RLMemoryCache *strongSelf = weakSelf;
                if (strongSelf)
                    block(strongSelf);
            });
        }
    });
}

- (void)trimToCost:(NSUInteger)cost block:(RLMemoryCacheBlock)block
{
    __weak RLMemoryCache *weakSelf = self;
    
    dispatch_barrier_async(_queue, ^{
        RLMemoryCache *strongSelf = weakSelf;
        if (!strongSelf)
            return;
        
        [strongSelf trimToCostLimit:cost];
        
        if (block) {
            __weak RLMemoryCache *weakSelf = strongSelf;
            dispatch_async(strongSelf->_queue, ^{
                RLMemoryCache *strongSelf = weakSelf;
                if (strongSelf)
                    block(strongSelf);
            });
        }
    });
}

- (void)trimToCostByDate:(NSUInteger)cost block:(RLMemoryCacheBlock)block
{
    __weak RLMemoryCache *weakSelf = self;
    
    dispatch_barrier_async(_queue, ^{
        RLMemoryCache *strongSelf = weakSelf;
        if (!strongSelf)
            return;
        
        [strongSelf trimToCostLimitByDate:cost];
        
        if (block) {
            __weak RLMemoryCache *weakSelf = strongSelf;
            dispatch_async(strongSelf->_queue, ^{
                RLMemoryCache *strongSelf = weakSelf;
                if (strongSelf)
                    block(strongSelf);
            });
        }
    });
}

- (void)removeAllObjects:(RLMemoryCacheBlock)block
{
    __weak RLMemoryCache *weakSelf = self;
    
    dispatch_barrier_async(_queue, ^{
        RLMemoryCache *strongSelf = weakSelf;
        if (!strongSelf)
            return;
        
        if (strongSelf->_willRemoveAllObjectsBlock)
            strongSelf->_willRemoveAllObjectsBlock(strongSelf);
        
        [strongSelf->_dictionary removeAllObjects];
        [strongSelf->_dates removeAllObjects];
        [strongSelf->_costs removeAllObjects];
        
        strongSelf->_totalCost = 0;
        
        if (strongSelf->_didRemoveAllObjectsBlock)
            strongSelf->_didRemoveAllObjectsBlock(strongSelf);
        
        if (block) {
            __weak RLMemoryCache *weakSelf = strongSelf;
            dispatch_async(strongSelf->_queue, ^{
                RLMemoryCache *strongSelf = weakSelf;
                if (strongSelf)
                    block(strongSelf);
            });
        }
    });
}

- (void)enumerateObjectsWithBlock:(RLMemoryCacheObjectBlock)block completionBlock:(RLMemoryCacheBlock)completionBlock
{
    if (!block)
        return;
    
    __weak RLMemoryCache *weakSelf = self;
    
    dispatch_barrier_async(_queue, ^{
        RLMemoryCache *strongSelf = weakSelf;
        if (!strongSelf)
            return;
        
        NSArray *keysSortedByDate = [strongSelf->_dates keysSortedByValueUsingSelector:@selector(compare:)];
        
        for (NSString *key in keysSortedByDate) {
            block(strongSelf, key, [strongSelf->_dictionary objectForKey:key]);
        }
        
        if (completionBlock) {
            __weak RLMemoryCache *weakSelf = strongSelf;
            dispatch_async(strongSelf->_queue, ^{
                RLMemoryCache *strongSelf = weakSelf;
                if (strongSelf)
                    completionBlock(strongSelf);
            });
        }
    });
}

#pragma mark - Public Synchronous Methods -

- (id)objectForKey:(NSString *)key
{
    if (!key)
        return nil;
    
    __block id objectForKey = nil;
    
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    
    [self objectForKey:key block:^(RLMemoryCache *cache, NSString *key, id object) {
        objectForKey = object;
        dispatch_semaphore_signal(semaphore);
    }];
    
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    
#if !OS_OBJECT_USE_OBJC
    dispatch_release(semaphore);
#endif
    
    return objectForKey;
}

- (void)setObject:(id)object forKey:(NSString *)key
{
    [self setObject:object forKey:key withCost:0];
}

- (void)setObject:(id)object forKey:(NSString *)key withCost:(NSUInteger)cost
{
    if (!object || !key)
        return;
    
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    
    [self setObject:object forKey:key withCost:cost block:^(RLMemoryCache *cache, NSString *key, id object) {
        dispatch_semaphore_signal(semaphore);
    }];
    
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    
#if !OS_OBJECT_USE_OBJC
    dispatch_release(semaphore);
#endif
}

- (void)removeObjectForKey:(NSString *)key
{
    if (!key)
        return;
    
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    
    [self removeObjectForKey:key block:^(RLMemoryCache *cache, NSString *key, id object) {
        dispatch_semaphore_signal(semaphore);
    }];
    
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    
#if !OS_OBJECT_USE_OBJC
    dispatch_release(semaphore);
#endif
}

- (void)trimToDate:(NSDate *)date
{
    if (!date)
        return;
    
    if ([date isEqualToDate:[NSDate distantPast]]) {
        [self removeAllObjects];
        return;
    }
    
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    
    [self trimToDate:date block:^(RLMemoryCache *cache) {
        dispatch_semaphore_signal(semaphore);
    }];
    
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    
#if !OS_OBJECT_USE_OBJC
    dispatch_release(semaphore);
#endif
}

- (void)trimToCost:(NSUInteger)cost
{
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    
    [self trimToCost:cost block:^(RLMemoryCache *cache) {
        dispatch_semaphore_signal(semaphore);
    }];
    
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    
#if !OS_OBJECT_USE_OBJC
    dispatch_release(semaphore);
#endif
}

- (void)trimToCostByDate:(NSUInteger)cost
{
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    
    [self trimToCostByDate:cost block:^(RLMemoryCache *cache) {
        dispatch_semaphore_signal(semaphore);
    }];
    
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    
#if !OS_OBJECT_USE_OBJC
    dispatch_release(semaphore);
#endif
}

- (void)removeAllObjects
{
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    
    [self removeAllObjects:^(RLMemoryCache *cache) {
        dispatch_semaphore_signal(semaphore);
    }];
    
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    
#if !OS_OBJECT_USE_OBJC
    dispatch_release(semaphore);
#endif
}

- (void)enumerateObjectsWithBlock:(RLMemoryCacheObjectBlock)block
{
    if (!block)
        return;
    
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    
    [self enumerateObjectsWithBlock:block completionBlock:^(RLMemoryCache *cache) {
        dispatch_semaphore_signal(semaphore);
    }];
    
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    
#if !OS_OBJECT_USE_OBJC
    dispatch_release(semaphore);
#endif
}



- (RLMemoryCacheObjectBlock)willAddObjectBlock
{
    __block RLMemoryCacheObjectBlock block = nil;
    
    dispatch_sync(_queue, ^{
        block = self->_willAddObjectBlock;
    });
    
    return block;
}

- (void)setWillAddObjectBlock:(RLMemoryCacheObjectBlock)block
{
    __weak RLMemoryCache *weakSelf = self;
    
    dispatch_barrier_async(_queue, ^{
        RLMemoryCache *strongSelf = weakSelf;
        if (!strongSelf)
            return;
        
        strongSelf->_willAddObjectBlock = [block copy];
    });
}

- (RLMemoryCacheObjectBlock)willRemoveObjectBlock
{
    __block RLMemoryCacheObjectBlock block = nil;
    
    dispatch_sync(_queue, ^{
        block = _willRemoveObjectBlock;
    });
    
    return block;
}

- (void)setWillRemoveObjectBlock:(RLMemoryCacheObjectBlock)block
{
    __weak RLMemoryCache *weakSelf = self;
    
    dispatch_barrier_async(_queue, ^{
        RLMemoryCache *strongSelf = weakSelf;
        if (!strongSelf)
            return;
        
        strongSelf->_willRemoveObjectBlock = [block copy];
    });
}

- (RLMemoryCacheBlock)willRemoveAllObjectsBlock
{
    __block RLMemoryCacheBlock block = nil;
    
    dispatch_sync(_queue, ^{
        block = _willRemoveAllObjectsBlock;
    });
    
    return block;
}

- (void)setWillRemoveAllObjectsBlock:(RLMemoryCacheBlock)block
{
    __weak RLMemoryCache *weakSelf = self;
    
    dispatch_barrier_async(_queue, ^{
        RLMemoryCache *strongSelf = weakSelf;
        if (!strongSelf)
            return;
        
        strongSelf->_willRemoveAllObjectsBlock = [block copy];
    });
}

- (RLMemoryCacheObjectBlock)didAddObjectBlock
{
    __block RLMemoryCacheObjectBlock block = nil;
    
    dispatch_sync(_queue, ^{
        block = _didAddObjectBlock;
    });
    
    return block;
}

- (void)setDidAddObjectBlock:(RLMemoryCacheObjectBlock)block
{
    __weak RLMemoryCache *weakSelf = self;
    
    dispatch_barrier_async(_queue, ^{
        RLMemoryCache *strongSelf = weakSelf;
        if (!strongSelf)
            return;
        
        strongSelf->_didAddObjectBlock = [block copy];
    });
}

- (RLMemoryCacheObjectBlock)didRemoveObjectBlock
{
    __block RLMemoryCacheObjectBlock block = nil;
    
    dispatch_sync(_queue, ^{
        block = _didRemoveObjectBlock;
    });
    
    return block;
}

- (void)setDidRemoveObjectBlock:(RLMemoryCacheObjectBlock)block
{
    __weak RLMemoryCache *weakSelf = self;
    
    dispatch_barrier_async(_queue, ^{
        RLMemoryCache *strongSelf = weakSelf;
        if (!strongSelf)
            return;
        
        strongSelf->_didRemoveObjectBlock = [block copy];
    });
}

- (RLMemoryCacheBlock)didRemoveAllObjectsBlock
{
    __block RLMemoryCacheBlock block = nil;
    
    dispatch_sync(_queue, ^{
        block = _didRemoveAllObjectsBlock;
    });
    
    return block;
}

- (void)setDidRemoveAllObjectsBlock:(RLMemoryCacheBlock)block
{
    __weak RLMemoryCache *weakSelf = self;
    
    dispatch_barrier_async(_queue, ^{
        RLMemoryCache *strongSelf = weakSelf;
        if (!strongSelf)
            return;
        
        strongSelf->_didRemoveAllObjectsBlock = [block copy];
    });
}

- (RLMemoryCacheBlock)didReceiveMemoryWarningBlock
{
    __block RLMemoryCacheBlock block = nil;
    
    dispatch_sync(_queue, ^{
        block = _didReceiveMemoryWarningBlock;
    });
    
    return block;
}

- (void)setDidReceiveMemoryWarningBlock:(RLMemoryCacheBlock)block
{
    __weak RLMemoryCache *weakSelf = self;
    
    dispatch_barrier_async(_queue, ^{
        RLMemoryCache *strongSelf = weakSelf;
        if (!strongSelf)
            return;
        
        strongSelf->_didReceiveMemoryWarningBlock = [block copy];
    });
}

- (RLMemoryCacheBlock)didEnterBackgroundBlock
{
    __block RLMemoryCacheBlock block = nil;
    
    dispatch_sync(_queue, ^{
        block = _didEnterBackgroundBlock;
    });
    
    return block;
}

- (void)setDidEnterBackgroundBlock:(RLMemoryCacheBlock)block
{
    __weak RLMemoryCache *weakSelf = self;
    
    dispatch_barrier_async(_queue, ^{
        RLMemoryCache *strongSelf = weakSelf;
        if (!strongSelf)
            return;
        
        strongSelf->_didEnterBackgroundBlock = [block copy];
    });
}

- (NSTimeInterval)ageLimit
{
    __block NSTimeInterval ageLimit = 0.0;
    
    dispatch_sync(_queue, ^{
        ageLimit = _ageLimit;
    });
    
    return ageLimit;
}

- (void)setAgeLimit:(NSTimeInterval)ageLimit
{
    __weak RLMemoryCache *weakSelf = self;
    
    dispatch_barrier_async(_queue, ^{
        RLMemoryCache *strongSelf = weakSelf;
        if (!strongSelf)
            return;
        
        strongSelf->_ageLimit = ageLimit;
        
        [strongSelf trimToAgeLimitRecursively];
    });
}

- (NSUInteger)costLimit
{
    __block NSUInteger costLimit = 0;
    
    dispatch_sync(_queue, ^{
        costLimit = _costLimit;
    });
    
    return costLimit;
}

- (void)setCostLimit:(NSUInteger)costLimit
{
    __weak RLMemoryCache *weakSelf = self;
    
    dispatch_barrier_async(_queue, ^{
        RLMemoryCache *strongSelf = weakSelf;
        if (!strongSelf)
            return;
        
        strongSelf->_costLimit = costLimit;
        
        if (costLimit > 0)
            [strongSelf trimToCostLimitByDate:costLimit];
    });
}

- (NSUInteger)totalCost
{
    __block NSUInteger cost = 0;
    
    dispatch_sync(_queue, ^{
        cost = _totalCost;
    });
    
    return cost;
}




@end


#pragma mark - RLCache

NSString * const RLCachePrefix = @"com.repeatlink.rlterm3.RLCache";
NSString * const RLCacheSharedName = @"RLCacheShared";
@interface RLCache ()
@property (strong, nonatomic) dispatch_queue_t queue;
@end
@implementation RLCache
- (instancetype)initWithName:(NSString *)name
{
    return [self initWithName:name rootPath:[NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) objectAtIndex:0]];
}

- (instancetype)initWithName:(NSString *)name rootPath:(NSString *)rootPath
{
    if (!name)
        return nil;
    
    if (self = [super init]) {
        _name = [name copy];
        self.type = kRLCacheUseTypeUseMemoryAndDiskCache;
        NSString *queueName = [[NSString alloc] initWithFormat:@"%@.%p", RLCachePrefix, self];
        _queue = dispatch_queue_create([queueName UTF8String], DISPATCH_QUEUE_CONCURRENT);
        
        _diskCache = [[RLDiskCache alloc] initWithName:_name rootPath:rootPath];
        _memoryCache = [[RLMemoryCache alloc] init];
    }
    return self;
}

- (NSString *)description
{
    return [[NSString alloc] initWithFormat:@"%@.%@.%p", RLCachePrefix, _name, self];
}

+ (instancetype)sharedCache
{
    static id cache;
    static dispatch_once_t predicate;
    
    dispatch_once(&predicate, ^{
        cache = [[self alloc] initWithName:RLCacheSharedName];
    });
    
    return cache;
}




-(void)objectForKey:(NSString *)key block:(RLCacheObjectBlock)block{
    if (!key || !block)
        return;
    
     __weak RLCache *weakSelf = self;
    dispatch_async(_queue, ^{
        RLCache *strongSelf = weakSelf;
        if (!strongSelf)
            return;
        
        __weak RLCache *weakSelf = strongSelf;
        
        [strongSelf->_memoryCache objectForKey:key block:^(RLMemoryCache *cache, NSString *key, id object) {
            RLCache *strongSelf = weakSelf;
            if (!strongSelf)
                return;
            
            if (object) {
                RLCacheObject *cacheObject = object;
                if([cacheObject.expiryDate isInThePast]){
                    __weak RLCache *weakSelf = strongSelf;
                    
                    dispatch_async(strongSelf->_queue, ^{
                        RLCache *strongSelf = weakSelf;
                        if (strongSelf)
                            block(strongSelf, key, nil);
                    });
                    
                    [strongSelf->_memoryCache removeObjectForKey:key block:^(RLMemoryCache *cache, NSString *key, id object) {
                        
                    }];
                    
                    
                }else{
                    
                    [strongSelf->_diskCache fileURLForKey:key block:^(RLDiskCache *cache, NSString *key, id <NSCoding> object, NSURL *fileURL) {
                        // update the access time on disk
                    }];
                    
                    __weak RLCache *weakSelf = strongSelf;
                    
                    dispatch_async(strongSelf->_queue, ^{
                        RLCache *strongSelf = weakSelf;
                        if (strongSelf)
                            block(strongSelf, key, cacheObject.value);
                    });

                }
                
            } else {
                __weak RLCache *weakSelf = strongSelf;
                
                [strongSelf->_diskCache objectForKey:key block:^(RLDiskCache *cache, NSString *key, id <NSCoding> object, NSURL *fileURL) {
                    RLCache *strongSelf = weakSelf;
                    RLCacheObject *cacheObject = object;
                    if (!strongSelf)
                        return;
                    
                    
                    if(cacheObject && [cacheObject.expiryDate isInThePast]){
                       
                        __weak RLCache *weakSelf = strongSelf;
                        
                        dispatch_async(strongSelf->_queue, ^{
                            RLCache *strongSelf = weakSelf;
                            if (strongSelf)
                                block(strongSelf, key, nil);
                        });

                        
                        [strongSelf->_memoryCache removeObjectForKey:key block:^(RLMemoryCache *cache, NSString *key, id object) {
                           
                           
                        }];
                    }else{
                        if( (self.type & kRLCacheUseTypeUseMemoryCacheOnly)  == kRLCacheUseTypeUseMemoryCacheOnly){
                            [strongSelf->_memoryCache setObject:object forKey:key block:nil];
                        }
                        
                        
                        __weak RLCache *weakSelf = strongSelf;
                        
                        dispatch_async(strongSelf->_queue, ^{
                            RLCache *strongSelf = weakSelf;
                            if (strongSelf)
                                block(strongSelf, key, cacheObject.value);
                        });

                    }
                }];
            }
        }];
    });

    
}



- (void)setObject:(id <NSCoding>)object forKey:(NSString *)key block:(RLCacheObjectBlock)block
{
    [self setObject:object forKey:key withExpiryDate:[NSDate distantFuture] block:block];
}

- (void)setObject:(id <NSCoding>)object forKey:(NSString *)key withExpiryDate:(NSDate *)date block:(RLCacheObjectBlock)block{
    
    if (!key || !object)
        return;
    
    dispatch_group_t group = nil;
    RLMemoryCacheObjectBlock memBlock = nil;
    RLDiskCacheObjectBlock diskBlock = nil;
    
    if (block) {
        group = dispatch_group_create();
        dispatch_group_enter(group);
        dispatch_group_enter(group);
        
        memBlock = ^(RLMemoryCache *cache, NSString *key, id object) {
            dispatch_group_leave(group);
        };
        
        diskBlock = ^(RLDiskCache *cache, NSString *key, id <NSCoding> object, NSURL *fileURL) {
            dispatch_group_leave(group);
        };
    }
    RLCacheObject *cacheObject = [[RLCacheObject alloc] initWithValue:object expiryDate:date];
    if( (self.type & kRLCacheUseTypeUseMemoryCacheOnly)  == kRLCacheUseTypeUseMemoryCacheOnly){
        [_memoryCache setObject:cacheObject forKey:key block:memBlock];
    }
    
    if((self.type  & kRLCacheUseTypeUseDiskCacheOnly) == kRLCacheUseTypeUseDiskCacheOnly){
         [_diskCache setObject:cacheObject forKey:key block:diskBlock];
    }
   
    
    if (group) {
        __weak RLCache *weakSelf = self;
        dispatch_group_notify(group, _queue, ^{
            RLCache *strongSelf = weakSelf;
            if (strongSelf)
                if(block)
                    block(strongSelf, key, object);
        });
        
#if !OS_OBJECT_USE_OBJC
        dispatch_release(group);
#endif
    }
}

- (void)removeObjectForKey:(NSString *)key block:(RLCacheObjectBlock)block
{
    if (!key)
        return;
    
    dispatch_group_t group = nil;
    RLMemoryCacheObjectBlock memBlock = nil;
    RLDiskCacheObjectBlock diskBlock = nil;
    
    if (block) {
        group = dispatch_group_create();
        dispatch_group_enter(group);
        dispatch_group_enter(group);
        
        memBlock = ^(RLMemoryCache *cache, NSString *key, id object) {
            dispatch_group_leave(group);
        };
        
        diskBlock = ^(RLDiskCache *cache, NSString *key, id <NSCoding> object, NSURL *fileURL) {
            dispatch_group_leave(group);
        };
    }
    
    [_memoryCache removeObjectForKey:key block:memBlock];
    [_diskCache removeObjectForKey:key block:diskBlock];
    
    if (group) {
        __weak RLCache *weakSelf = self;
        dispatch_group_notify(group, _queue, ^{
            RLCache *strongSelf = weakSelf;
            if (strongSelf)
                block(strongSelf, key, nil);
        });
        
#if !OS_OBJECT_USE_OBJC
        dispatch_release(group);
#endif
    }
}

- (void)removeAllObjects:(RLCacheBlock)block
{
    dispatch_group_t group = nil;
    RLMemoryCacheBlock memBlock = nil;
    RLDiskCacheBlock diskBlock = nil;
    
    if (block) {
        group = dispatch_group_create();
        dispatch_group_enter(group);
        dispatch_group_enter(group);
        
        memBlock = ^(RLMemoryCache *cache) {
            dispatch_group_leave(group);
        };
        
        diskBlock = ^(RLDiskCache *cache) {
            dispatch_group_leave(group);
        };
    }
    
    [_memoryCache removeAllObjects:memBlock];
    [_diskCache removeAllObjects:diskBlock];
    
    if (group) {
        __weak RLCache *weakSelf = self;
        dispatch_group_notify(group, _queue, ^{
            RLCache *strongSelf = weakSelf;
            if (strongSelf)
                block(strongSelf);
        });
        
#if !OS_OBJECT_USE_OBJC
        dispatch_release(group);
#endif
    }
}



- (void)trimToDate:(NSDate *)date block:(RLCacheBlock)block
{
    if (!date)
        return;
    
    dispatch_group_t group = nil;
    RLMemoryCacheBlock memBlock = nil;
    RLDiskCacheBlock diskBlock = nil;
    
    if (block) {
        group = dispatch_group_create();
        dispatch_group_enter(group);
        dispatch_group_enter(group);
        
        memBlock = ^(RLMemoryCache *cache) {
            dispatch_group_leave(group);
        };
        
        diskBlock = ^(RLDiskCache *cache) {
            dispatch_group_leave(group);
        };
    }
    
    [_memoryCache trimToDate:date block:memBlock];
    [_diskCache trimToDate:date block:diskBlock];
    
    if (group) {
        __weak RLCache *weakSelf = self;
        dispatch_group_notify(group, _queue, ^{
            RLCache *strongSelf = weakSelf;
            if (strongSelf)
                block(strongSelf);
        });
        
#if !OS_OBJECT_USE_OBJC
        dispatch_release(group);
#endif
    }
}


- (NSUInteger)diskByteCount
{
    __block NSUInteger byteCount = 0;
    
    dispatch_sync([RLDiskCache sharedQueue], ^{
        byteCount = self.diskCache.byteCount;
    });
    
    return byteCount;
}


- (id)objectForKey:(NSString *)key
{
    if (!key)
        return nil;
    
    __block id objectForKey = nil;
    
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    
    [self objectForKey:key block:^(RLCache *cache, NSString *key, id object) {
        objectForKey = object;
        dispatch_semaphore_signal(semaphore);
    }];
    
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    
#if !OS_OBJECT_USE_OBJC
    dispatch_release(semaphore);
#endif
    
    return objectForKey;
}

- (void)setObject:(id <NSCoding>)object forKey:(NSString *)key
{
    [self setObject:object forKey:key withExpiryDate:[NSDate distantFuture]];
}

- (void)setObject:(id <NSCoding>)object forKey:(NSString *)key withExpiryDate:(NSDate *)date{
    if (!object || !key)
        return;
    
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    
    [self setObject:object forKey:key withExpiryDate:date block:^(RLCache *cache, NSString *key, id object) {
        dispatch_semaphore_signal(semaphore);
    }];
    
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    
#if !OS_OBJECT_USE_OBJC
    dispatch_release(semaphore);
#endif

}
- (void)removeObjectForKey:(NSString *)key
{
    if (!key)
        return;
    
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    
    [self removeObjectForKey:key block:^(RLCache *cache, NSString *key, id object) {
        dispatch_semaphore_signal(semaphore);
    }];
    
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    
#if !OS_OBJECT_USE_OBJC
    dispatch_release(semaphore);
#endif
}


- (void)trimToDate:(NSDate *)date
{
    if (!date)
        return;
    
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    
    [self trimToDate:date block:^(RLCache *cache) {
        dispatch_semaphore_signal(semaphore);
    }];
    
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    
#if !OS_OBJECT_USE_OBJC
    dispatch_release(semaphore);
#endif
}


- (void)removeAllObjects
{
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    
    [self removeAllObjects:^(RLCache *cache) {
        dispatch_semaphore_signal(semaphore);
    }];
    
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    
#if !OS_OBJECT_USE_OBJC
    dispatch_release(semaphore);
#endif
}


@end
