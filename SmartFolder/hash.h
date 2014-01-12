
#ifndef SmartFolder_hash_h
#define SmartFolder_hash_h

#include <CoreFoundation/CoreFoundation.h>
#include <string>

std::string FileSHA1HashCreateWithPath(CFStringRef filePath, size_t chunkSizeForReadingData);

#endif
