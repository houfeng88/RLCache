//
//  RLCache.swift
//  rlterm3
//
//  Created by Repeatlink-HouFeng on 16/5/11.
//  Copyright © 2016年 RepeatLink. All rights reserved.
//

import Foundation

class RLCacheObject:NSObject,NSCoding{
    let value:AnyObject
    let expiryDate:NSDate
    init(value:AnyObject,expiryDate:NSDate) {
        self.value = value
        self.expiryDate = expiryDate
    }
    
    func isExpired() -> Bool{
        return expiryDate.isInThePast
    }
    
    required init?(coder aDecoder:NSCoder){
    
        guard  let val = aDecoder.decodeObjectForKey("value") ,  let expiry = aDecoder.decodeObjectForKey("expiryDate") as? NSDate else{
            value = NSObject()
            expiryDate = NSDate.distantPast()
            super.init()
            return nil
        }
        self.value = val
        self.expiryDate = expiry
        super.init()
    }
    
    func encodeWithCoder(aCoder: NSCoder) {
        aCoder.encodeObject(value, forKey: "value")
        aCoder.encodeObject(expiryDate, forKey: "expiryDate")
    }
    
    
}
extension NSDate{
    var isInThePast:Bool{
        return self.timeIntervalSinceNow < 0
    }
}

public enum RLCacheExpiry{
    case Nerver
    case Seconds(NSTimeInterval)
    case Date(NSDate)
}



public class RLCache<T:NSCoding> {
    public let name:String
    public let cacheDirectroy:NSURL
    
    internal let  cache = NSCache()
    
    private let fileManager = NSFileManager()
    private let diskWriteQueue:dispatch_queue_t  = dispatch_queue_create("com.repeatlink.rlterm3.cache.diskwritequeue", DISPATCH_QUEUE_SERIAL)
    private let diskReadQueue:dispatch_queue_t = dispatch_queue_create("com.repeatlink.rlterm3.cache.diskwritequeue", DISPATCH_QUEUE_SERIAL)
    public typealias RLCacheBlockClosure = (T,RLCacheExpiry) -> Void
    public typealias RLErrorClosure = (NSError?) -> Void
    
    public init(name:String,directory:NSURL?) throws{
        self.name = name
        cache.name  = name
        if let  d = directory {
            cacheDirectroy = d
        }else{
            let cachesUrl = NSFileManager.defaultManager().URLsForDirectory(.CachesDirectory, inDomains: .UserDomainMask).first!
            cacheDirectroy = (cachesUrl.URLByAppendingPathComponent("com.repeatlink.rlterm3.cache/\(name)"))
        }
        try fileManager.createDirectoryAtURL(cacheDirectroy, withIntermediateDirectories: true, attributes: nil)
        
    }
    
    public convenience init(name:String) throws{
        try self.init(name:name,directory: nil)
    }
    
    public func setObjectForKey(key:String , cacheBlock:(RLCacheBlockClosure,RLErrorClosure) -> Void , completion:(T?,Bool,NSError?) -> Void) {
        if let object = objectForKey(key) {
            completion(object,true,nil)
        }else {
            let successBlock:RLCacheBlockClosure = { (obj,expires) in
                self.setObject(obj, forKey: key, expires: expires)
                completion(obj,false,nil)
            }
            let failureBlock:RLErrorClosure = { (error) in
                completion(nil,false,error)
            }
            cacheBlock(successBlock,failureBlock)
        }
    }
    
    public func objectForKey(key:String) -> T?{
        var possibleObject = cache.objectForKey(key) as? RLCacheObject
        if possibleObject == nil {
            dispatch_sync(diskReadQueue){
                if let  path = self.urlForKey(key).path where self.fileManager.fileExistsAtPath(path){
                    possibleObject = NSKeyedUnarchiver.unarchiveObjectWithFile(path) as? RLCacheObject
                    if let obj = possibleObject {
                        self.cache.setObject(obj, forKey: key)
                    }
                    
                }
            }
            
        }
        if let object = possibleObject{
            if !object.isExpired() {
                return object.value as? T
            }else{
                removeObjectForKey(key)
            }
        }
        
        return nil
    }
    
    public func setObject(object:T ,forKey key:String ,expires:RLCacheExpiry = .Nerver){
        setObject(object, forKey: key, expires: expires ,completion: {})
    }
    
    internal func setObject(object:T,forKey key:String, expires :RLCacheExpiry = .Nerver ,completion:() ->Void ){
         let expiryDate = expiryDateForCacheExpiry(expires)
         let cacheObject = RLCacheObject(value: object, expiryDate: expiryDate)
         cache.setObject(cacheObject, forKey: key)
        dispatch_async(diskWriteQueue) {
            if let path = self.urlForKey(key).path {
                NSKeyedArchiver.archiveRootObject(cacheObject, toFile: path)
            }
            completion()
        }
    }
    
    
    public func removeObjectForKey(key: String) {
        cache.removeObjectForKey(key)
        
        dispatch_async(diskWriteQueue) {
            let url = self.urlForKey(key)
            let _ = try? self.fileManager.removeItemAtURL(url)
        }
    }
    
    
    public func removeAllObjects(completion: (() -> Void)? = nil) {
        cache.removeAllObjects()
        
        dispatch_async(diskWriteQueue) {
            let keys = self.allKeys()
            
            for key in keys {
                let url = self.urlForKey(key)
                let _  = try? self.fileManager.removeItemAtURL(url)
            }
            
            dispatch_async(dispatch_get_main_queue()) {
                completion?()
            }
        }
    }
    
    public func removeExpiredObjects() {
        dispatch_async(diskWriteQueue) {
            let keys = self.allKeys()
            
            for key in keys {
                self.objectForKey(key)
            }
        }
    }

    public subscript(key: String) -> T? {
        get {
            return objectForKey(key)
        }
        set(newValue) {
            if let value = newValue {
                setObject(value, forKey: key)
            } else {
                removeObjectForKey(key)
            }
        }
    }
    
    
    // MARK: helper func
    
    private func allKeys() -> [String] {
        let urls = try? self.fileManager.contentsOfDirectoryAtURL(self.cacheDirectroy, includingPropertiesForKeys: nil, options: [])
        return urls?.flatMap { $0.URLByDeletingPathExtension?.lastPathComponent } ?? []
    }
    
    private func urlForKey(key: String) -> NSURL {
        let k = sanitizedKey(key)
        return cacheDirectroy
            .URLByAppendingPathComponent(k)
            .URLByAppendingPathExtension("cache")
    }

    
    private func sanitizedKey(key: String) -> String {
        return key.stringByReplacingOccurrencesOfString("[^a-zA-Z0-9_]+", withString: "-", options: .RegularExpressionSearch, range: nil)
    }
    
    private func expiryDateForCacheExpiry(expiry:RLCacheExpiry) -> NSDate {
        switch expiry {
        case .Nerver:
            return NSDate.distantFuture()
        case .Seconds(let seconds):
            return NSDate().dateByAddingTimeInterval(seconds)
        case .Date(let date):
            return date
        }
    }
    
    
}

public class RLStringCache{
    private let cache :RLCache<NSString>
    public init(name:String,path:NSURL? = nil){
       try! self.cache = RLCache<NSString>(name:name,directory: path)
    }
    public func setObject(object:NSString ,forKey key:String ,expires:RLCacheExpiry = .Nerver){
        self.cache.setObject(object, forKey: key, expires: expires)
    }
    
}
