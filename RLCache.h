//
//  RLCache.h
//  rlterm3
//
//  Created by Repeatlink-HouFeng on 16/5/18.
//  Copyright © 2016年 RepeatLink. All rights reserved.
//
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>





@class RLDiskCache;
@class RLMemoryCache;
@class RLCache;

typedef void (^RLCacheBlock)(RLCache *cache);
typedef void (^RLCacheObjectBlock)(RLCache *cache,NSString *key,id object);

typedef  NS_OPTIONS(NSInteger, RLCacheUseType) {
    kRLCacheUseTypeUseNone = 0,// none
    kRLCacheUseTypeUseMemoryCacheOnly = 1 << 0,// 只使用内存缓存
    kRLCacheUseTypeUseDiskCacheOnly =  1 << 1,// 只使用物理缓存
    kRLCacheUseTypeUseMemoryAndDiskCache =  kRLCacheUseTypeUseMemoryCacheOnly | kRLCacheUseTypeUseDiskCacheOnly,// 内存和物理缓存都使用
    
};

/*
 缓存对象，可以缓存实现了NSCoding协议的对象，
 可以缓存到内存，或者硬盘中，默认情况下是缓存到内存加硬盘
 可以调用 initWithName：方法生为没个模块单独生成缓存对象。
 也可以使用 sharedCache方法 使用全局缓存对象
 
 */

@interface RLCache : NSObject

@property(nonatomic)RLCacheUseType type;
/*
 缓存的名字，用来创建 文件缓存 diskcache
 */
@property(readonly) NSString *name;
/*
 并行队列，无阻塞模式
 */
@property(readonly) dispatch_queue_t queue;

/*
 最大能容纳多少byte
 */
@property(readonly)NSUInteger diskByteCount;

/*
 硬盘缓存对象
 */
@property(readonly)RLDiskCache *diskCache;
/*
 内存缓存对象
 */
@property(readonly)RLMemoryCache *memoryCache;


- (instancetype)init UNAVAILABLE_ATTRIBUTE;
+ (instancetype)new UNAVAILABLE_ATTRIBUTE;

/*
    全局缓存对象
 */
+(instancetype)sharedCache;

/*
    每个需要缓存的数据可以调用生成单独的缓存对象
 */
- (instancetype)initWithName:(NSString *)name;
/*
    设置缓存的位置
 */
-(instancetype)initWithName:(NSString *)name rootPath:(NSString *)rootPath;

/*
    异步获取，设置数据方法
 */
-(void)objectForKey:(NSString *)key block:(RLCacheObjectBlock)block;

- (void)setObject:(id <NSCoding>)object forKey:(NSString *)key block:(RLCacheObjectBlock)block;

// 设置时候指定过期时间
- (void)setObject:(id <NSCoding>)object forKey:(NSString *)key withExpiryDate:(NSDate *)date block:(RLCacheObjectBlock)block;


-(void)removeObjectForKey:(NSString *)key block:(RLCacheObjectBlock)block;


-(void)trimToDate:(NSDate *)date block:(RLCacheBlock)block;

-(void)removeAllObjects:(RLCacheBlock)block;


/*
 异步获取，设置 数据方法
 */

-(id)objectForKey:(NSString *)key;

- (void)setObject:(id <NSCoding>)object forKey:(NSString *)key;

//设置时候指定过期时间
- (void)setObject:(id <NSCoding>)object forKey:(NSString *)key withExpiryDate:(NSDate *)date;


- (void)removeObjectForKey:(NSString *)key;

- (void)trimToDate:(NSDate *)date;

- (void)removeAllObjects;
@end






@interface RLCacheObject : NSObject<NSCoding>
@property(nonatomic,strong)id<NSCoding> value;
@property(nonatomic,strong)NSDate *expiryDate;
@end



typedef void (^RLDiskCacheBlock)(RLDiskCache *cache);
typedef void (^RLDiskCacheObjectBlock)(RLDiskCache *cache,NSString *key,id<NSCoding> object,NSURL *fileURL);



@protocol RLCacheBackgroundTaskManager <NSObject>
- (UIBackgroundTaskIdentifier)beginBackgroundTask;
- (void)endBackgroundTask:(UIBackgroundTaskIdentifier)identifier;
@end



/*
 硬盘缓存对象
 缓存数据到硬盘中
 */
@interface RLDiskCache:NSObject
@property(readonly)NSString *name;
@property(readonly)NSURL *cacheURL;

@property(readonly)NSUInteger byteCount;
@property(assign)NSUInteger byteLimit;//默认值为0 表示不限制大小。
@property(assign)NSTimeInterval ageLimit;//默认值为0 不限制缓存时间。

@property(copy)RLDiskCacheObjectBlock willAddObjectBlock;
@property(copy)RLDiskCacheObjectBlock willRemoveObjectBlock;

@property(copy)RLDiskCacheBlock willRemoveAllObjectsBlock;

@property(copy)RLDiskCacheObjectBlock didAddObjectBlock;

@property(copy)RLDiskCacheObjectBlock  didRemoveObjectBlock;

@property(copy)RLDiskCacheBlock didRemoveAllObjectsBlock;

+(instancetype)sharedCache;

//串行
+ (dispatch_queue_t)sharedQueue;

+(void)emptyTrash;

- (instancetype)initWithName:(NSString *)name;

- (instancetype)initWithName:(NSString *)name rootPath:(NSString *)rootPath;

- (void)objectForKey:(NSString *)key block:(RLDiskCacheObjectBlock)block;

-(void)fileURLForKey:(NSString *)key block:(RLDiskCacheObjectBlock)block;

-(void)setObject:(id<NSCoding>)object forKey:(NSString *)key block:(RLDiskCacheObjectBlock)block;

-(void)removeObjectForKey:(NSString *)key block:(RLDiskCacheObjectBlock)block;

-(void)trimToDate:(NSDate *)date block:(RLDiskCacheBlock)block;

-(void)trimToSize:(NSUInteger)byteCount block:(RLDiskCacheBlock)block;

-(void)trimToSizeByDate:(NSUInteger)byteCount block:(RLDiskCacheBlock)block;

-(void)removeAllObjects:(RLDiskCacheBlock)block;

-(void)enumerateObjectsWithBlock:(RLDiskCacheObjectBlock)block completionBlock:(RLDiskCacheBlock)completionBlock;

- (id <NSCoding>)objectForKey:(NSString *)key;

- (NSURL *)fileURLForKey:(NSString *)key;

- (void)setObject:(id <NSCoding>)object forKey:(NSString *)key;


- (void)removeObjectForKey:(NSString *)key;

- (void)trimToDate:(NSDate *)date;

- (void)trimToSize:(NSUInteger)byteCount;

- (void)trimToSizeByDate:(NSUInteger)byteCount;


- (void)removeAllObjects;

- (void)enumerateObjectsWithBlock:(RLDiskCacheObjectBlock)block;

+(void)setBackgroundTaskManager:(id<RLCacheBackgroundTaskManager>)backgroundTaskanager;


@end


#pragma mark RLMemoryCache

typedef void (^RLMemoryCacheBlock)(RLMemoryCache *cache);
typedef void (^RLMemoryCacheObjectBlock)(RLMemoryCache *cache, NSString *key, id object);


/*
  内存缓存对象，保存数据到内存中。
 */
@interface RLMemoryCache:NSObject

@property (readonly) dispatch_queue_t queue;
@property (readonly) NSUInteger totalCost;

@property (assign) NSUInteger costLimit;

@property (assign) NSTimeInterval ageLimit;

@property (assign) BOOL removeAllObjectsOnMemoryWarning;

@property (assign) BOOL removeAllObjectsOnEnteringBackground;

@property (copy) RLMemoryCacheObjectBlock willAddObjectBlock;

@property (copy) RLMemoryCacheObjectBlock willRemoveObjectBlock;



@property (copy) RLMemoryCacheBlock willRemoveAllObjectsBlock;



@property (copy) RLMemoryCacheObjectBlock didAddObjectBlock;

@property (copy) RLMemoryCacheObjectBlock didRemoveObjectBlock;

@property (copy) RLMemoryCacheBlock didRemoveAllObjectsBlock;



@property (copy) RLMemoryCacheBlock didReceiveMemoryWarningBlock;

@property (copy) RLMemoryCacheBlock didEnterBackgroundBlock;


+ (instancetype)sharedCache;

- (void)objectForKey:(NSString *)key block:(RLMemoryCacheObjectBlock)block;

- (void)setObject:(id)object forKey:(NSString *)key block:(RLMemoryCacheObjectBlock)block;


- (void)setObject:(id)object forKey:(NSString *)key withCost:(NSUInteger)cost block:(RLMemoryCacheObjectBlock)block;

- (void)removeObjectForKey:(NSString *)key block:(RLMemoryCacheObjectBlock)block;

- (void)trimToDate:(NSDate *)date block:(RLMemoryCacheBlock)block;

- (void)trimToCost:(NSUInteger)cost block:(RLMemoryCacheBlock)block;

- (void)trimToCostByDate:(NSUInteger)cost block:(RLMemoryCacheBlock)block;

- (void)removeAllObjects:(RLMemoryCacheBlock)block;
- (void)enumerateObjectsWithBlock:(RLMemoryCacheObjectBlock)block completionBlock:(RLMemoryCacheBlock)completionBlock;

- (id)objectForKey:(NSString *)key;

- (void)setObject:(id)object forKey:(NSString *)key;

- (void)setObject:(id)object forKey:(NSString *)key withCost:(NSUInteger)cost;
- (void)removeObjectForKey:(NSString *)key;

- (void)trimToDate:(NSDate *)date;
- (void)trimToCost:(NSUInteger)cost;
- (void)trimToCostByDate:(NSUInteger)cost;

- (void)removeAllObjects;

- (void)enumerateObjectsWithBlock:(RLMemoryCacheObjectBlock)block;
- (void)handleMemoryWarning;
- (void)handleApplicationBackgrounding __deprecated_msg("没有使用了");

@end



