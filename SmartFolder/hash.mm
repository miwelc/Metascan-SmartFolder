#include "hash.h"

// Standard library
#include <stdint.h>
#include <stdio.h>

// Cryptography
#include <CommonCrypto/CommonDigest.h>

// In bytes
#define FileHashDefaultChunkSizeForReadingData 4096

// Function
std::string FileSHA1HashCreateWithPath(CFStringRef filePath,
                                      size_t chunkSizeForReadingData) {
    
    // Declare needed variables
	std::string result;
    CFReadStreamRef readStream = NULL;
	bool didSucceed;
    
    // Get the file URL
    CFURLRef fileURL = CFURLCreateWithFileSystemPath(kCFAllocatorDefault,
													(CFStringRef)filePath,
													 kCFURLPOSIXPathStyle,
													 (Boolean)false);
    if(!fileURL) {
		return NULL;
	}
    
    // Create and open the read stream
    readStream = CFReadStreamCreateWithFile(kCFAllocatorDefault,
                                            (CFURLRef)fileURL);
    if (!readStream) return NULL;
	
    didSucceed = (bool)CFReadStreamOpen(readStream);
    if (!didSucceed) {
		CFReadStreamClose(readStream);
        CFRelease(readStream);
		return NULL;
	}
    
    // Initialize the hash object
    CC_SHA1_CTX hashObject;
    CC_SHA1_Init(&hashObject);
    
    // Make sure chunkSizeForReadingData is valid
    if (!chunkSizeForReadingData) {
        chunkSizeForReadingData = FileHashDefaultChunkSizeForReadingData;
    }
    
    // Feed the data to the hash object
    bool hasMoreData = true;
    while (hasMoreData) {
        uint8_t buffer[chunkSizeForReadingData];
        CFIndex readBytesCount = CFReadStreamRead(readStream,
                                                  (UInt8 *)buffer,
                                                  (CFIndex)sizeof(buffer));
        if (readBytesCount == -1) break;
        if (readBytesCount == 0) {
            hasMoreData = false;
            continue;
        }
        CC_SHA1_Update(&hashObject,
                      (const void *)buffer,
                      (CC_LONG)readBytesCount);
    }
    
    // Check if the read operation succeeded
    didSucceed = !hasMoreData;
    
    // Compute the hash digest
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1_Final(digest, &hashObject);
    
    if(didSucceed) {
		// Compute the string result
		char hash[2 * sizeof(digest) + 1];
		for (size_t i = 0; i < sizeof(digest); ++i) {
			snprintf(hash + (2 * i), 3, "%02X", (int)(digest[i]));
		}
		result = hash;
	}
    
    
    if (readStream) {
        CFReadStreamClose(readStream);
        CFRelease(readStream);
    }
    if (fileURL) {
        CFRelease(fileURL);
    }
	
    return result;
}