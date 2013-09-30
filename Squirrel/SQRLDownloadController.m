//
//  SQRLDownloadController.m
//  Squirrel
//
//  Created by Keith Duncan on 26/09/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLDownloadController.h"

#import <CommonCrypto/CommonCrypto.h>

#import "SQRLFileManager.h"
#import "SQRLResumableDownload.h"

@interface SQRLDownloadController ()
@property (nonatomic, assign, readonly) dispatch_queue_t indexQueue;
@end

@implementation SQRLDownloadController

+ (instancetype)defaultDownloadController {
	static SQRLDownloadController *defaultDownloadController = nil;
	static dispatch_once_t defaultDownloadControllerPredicate = 0;

	dispatch_once(&defaultDownloadControllerPredicate, ^{
		defaultDownloadController = [[self alloc] init];
	});

	return defaultDownloadController;
}

- (id)init {
	self = [super init];
	if (self == nil) return nil;

	_indexQueue = dispatch_queue_create("com.github.Squirrel.SQRLDownloadController.index", DISPATCH_QUEUE_CONCURRENT);

	return self;
}

- (void)dealloc {
	dispatch_release(_indexQueue);
}

- (NSURL *)downloadStoreDirectory {
	return SQRLFileManager.fileManagerForCurrentApplication.URLForDownloadDirectory;
}

- (NSURL *)downloadStoreIndexFileLocation {
	return SQRLFileManager.fileManagerForCurrentApplication.URLForResumableDownloadStateFile;
}

- (BOOL)removeAllResumableDownloads:(NSError **)errorRef {
	return [NSFileManager.defaultManager removeItemAtURL:self.downloadStoreDirectory error:errorRef];
}

- (BOOL)coordinateReadingIndex:(NSError **)errorRef byAccessor:(void (^)(NSDictionary *))block {
	NSParameterAssert(block != nil);

	__block BOOL result = NO;

	dispatch_sync(self.indexQueue, ^{
		NSData *propertyListData = [NSData dataWithContentsOfURL:self.downloadStoreIndexFileLocation options:0 error:errorRef];
		if (propertyListData == nil) return;

		NSDictionary *propertyList = [NSKeyedUnarchiver unarchiveObjectWithData:propertyListData];
		if (propertyList == nil) return;

		block(propertyList);

		result = YES;
	});

	return result;
}

- (BOOL)coordinateWritingIndex:(NSError **)errorRef byAccessor:(NSDictionary * (^)(NSDictionary *))block {
	NSParameterAssert(block != nil);

	__block BOOL result = NO;

	dispatch_barrier_sync(self.indexQueue, ^{
		NSURL *fileLocation = self.downloadStoreIndexFileLocation;

		NSDictionary *propertyList = nil;

		NSData *propertyListData = [NSData dataWithContentsOfURL:fileLocation options:0 error:NULL];
		if (propertyListData == nil) {
			propertyList = @{};
		} else {
			propertyList = [NSKeyedUnarchiver unarchiveObjectWithData:propertyListData];
			if (propertyList == nil) return;
		}

		NSDictionary *newPropertyList = block(propertyList);
		if ([newPropertyList isEqual:propertyList]) return;

		NSData *newData = [NSKeyedArchiver archivedDataWithRootObject:newPropertyList];
		if (newData == nil) return;

		BOOL write = [newData writeToURL:fileLocation options:NSDataWritingAtomic error:errorRef];
		if (!write) return;

		result = YES;
	});

	return result;
}

+ (NSString *)keyForURL:(NSURL *)URL {
	return URL.absoluteString;
}

+ (NSString *)fileNameForURL:(NSURL *)URL {
	NSString *key = [self keyForURL:URL];
	return [self base16:[self SHA1:[key dataUsingEncoding:NSUTF8StringEncoding]]];
}

+ (NSData *)SHA1:(NSData *)data {
	unsigned char hash[CC_SHA1_DIGEST_LENGTH];
	CC_SHA1(data.bytes, (CC_LONG)data.length, hash);
	return [NSData dataWithBytes:hash length:sizeof(hash) / sizeof(*hash)];
}

+ (NSString *)base16:(NSData *)data {
	char const *alphabet = "0123456789ABCDEF"; // <http://tools.ietf.org/html/rfc4648#section-8>
	NSMutableString *base16 = [NSMutableString stringWithCapacity:data.length * 2];
	for (NSUInteger idx = 0; idx < data.length; idx++) {
		uint8_t byte = *((uint8_t *)data.bytes + idx);
		[base16 appendFormat:@"%c%c", alphabet[(byte & /* 0b11110000 */ 240) >> 4], alphabet[(byte & /* 0b00001111 */ 15)]];
	}
	return base16;
}

- (SQRLResumableDownload *)downloadForURL:(NSURL *)URL {
	NSParameterAssert(URL != nil);
	
	NSError *downloadError = nil;
	__block SQRLResumableDownload *download = nil;

	NSString *key = [self.class keyForURL:URL];

	[self coordinateReadingIndex:&downloadError byAccessor:^(NSDictionary *index) {
		download = index[key];
	}];

	if (download == nil) {
		NSURL *localURL = [self.downloadStoreDirectory URLByAppendingPathComponent:[self.class fileNameForURL:URL]];
		return [[SQRLResumableDownload alloc] initWithResponse:nil fileURL:localURL];
	}

	return download;
}

- (void)setDownload:(SQRLResumableDownload *)download forURL:(NSURL *)URL {
	NSParameterAssert(download.response != nil);
	NSParameterAssert(URL != nil);

	NSString *key = [self.class keyForURL:URL];

	NSError *writeError = nil;
	__unused BOOL write = [self coordinateWritingIndex:&writeError byAccessor:^(NSDictionary *index) {
		NSMutableDictionary *newIndex = [index mutableCopy];

		if (download != nil) {
			newIndex[key] = download;
		} else {
			[newIndex removeObjectForKey:key];
		}

		return newIndex;
	}];
}

@end