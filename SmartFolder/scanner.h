//
//  scanner.h
//  SmartFolder
//
//  Created by Miguel Cantón Cortés on 18/10/13.
//  Copyright (c) 2013 Miguel Cantón Cortés. All rights reserved.
//

#ifndef __SmartFolder__scanner__
#define __SmartFolder__scanner__

#include <unordered_map>
#include <unordered_set>
#include <string>
#include <time.h>
// Cryptography
#include <CommonCrypto/CommonDigest.h>
#include <pthread.h>
#include "json/json.h"
#include "DB.h"

#define MAX_UPLOAD_THREADS 3
#define MAX_RESULTS_THREADS 2
#define MIN_CHECK_INTERVAL 60 //seconds
#define MAX_CHECK_INTERVAL 600 //seconds

using namespace std;

class Scanner {
	private:
		static DB db;
		static bool dbLoaded;
		static bool finish;
		static string apiKey;
		static bool wrongApiKey;
		static bool exceededUsage;
		static time_t exceededUsageTime;
		static bool connectivity;
		static long rescanTime;
	
		static pthread_mutex_t connectivityMutex, rescanTimeMutex;
		static pthread_mutex_t apiKeyMutex, processedMutex, toBeProcessedMutex;
		static pthread_mutex_t nThreadsUploadMutex, nThreadsResultsMutex;
		
		
		enum ScanningState { NOT_SCANNED, SENDING, SCANNING, SCANNED };
		struct FileInfo {
			string path;
			ScanningState state;
			time_t date;
			time_t nextResultsCheck;
			int scanResult;
			string hash;
			string data_id;
		};
		static unordered_map<string, FileInfo> filesProcessed; //Indexed by hash of file
		static unordered_set<string> toBeProcessed;
	
		static int threadsUploadRunning;
		static int threadsResultsRunning;
	
		static size_t sendFileCallback(void *ptr, size_t size, size_t nmemb, void *userp);
		static size_t initScanCallback(char *ptr, size_t size, size_t nmemb, void *userdata);
		static size_t getResultsCallback(char *ptr, size_t size, size_t nmemb, void *userdata);
	
		static void loadDB();
		static bool saveChanges(FileInfo* file, bool insertion = false); //Save change both in memory and BD
		static void* workerThread(void* _file);
		static bool sendFileToScan(string file); //True if it can be processed now, false if not
		struct ResultsJSON {
			string data_id;
			string path;
			time_t dateSubmitted;
			Json::Reader reader;
		};
		static void* resultsThread(void* _results);
		static bool getResults(ResultsJSON* res); //True if it can be processed now, false if not
		static void notifyUser(string file, int scanResult);
	
	public:
		static void initialize(string workingDir);
		static bool connectivityIsOk();
		static void setAPIKey(const char* key);
		static string getAPIKey();
		static void setRescanTime(long time); //In seconds
		static void getInfectedFiles(DBResults* infectedList);
		static void* startScanning(void* _path);
		static void endScanning() { finish = true; };
		static void scanFile(string file);
		static void fileDeleted(string file);
};

#endif /* defined(__SmartFolder__scanner__) */
