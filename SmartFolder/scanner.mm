//
//  scanner.cpp
//  SmartFolder
//
//  Created by Miguel Cantón Cortés on 18/10/13.
//  Copyright (c) 2013 Miguel Cantón Cortés. All rights reserved.
//

#include "scanner.h"
#include "hash.h"

#include "SFAppDelegate.h"
extern SFAppDelegate *appDelegate;

#include <fstream>
#include <sys/stat.h>
#include <unistd.h>
#include <curl/curl.h>
#include <cstring>


DB Scanner::db;
bool Scanner::dbLoaded = false;
bool Scanner::finish = false;
string Scanner::apiKey = "";
bool Scanner::wrongApiKey = false;
bool Scanner::exceededUsage = false;
time_t Scanner::exceededUsageTime = 0;
bool Scanner::connectivity = true;
time_t Scanner::rescanTime = -1;
pthread_mutex_t Scanner::connectivityMutex = PTHREAD_MUTEX_INITIALIZER;
pthread_mutex_t Scanner::rescanTimeMutex = PTHREAD_MUTEX_INITIALIZER;
pthread_mutex_t Scanner::apiKeyMutex = PTHREAD_MUTEX_INITIALIZER;
pthread_mutex_t Scanner::toBeProcessedMutex = PTHREAD_MUTEX_INITIALIZER;
pthread_mutex_t Scanner::processedMutex = PTHREAD_MUTEX_INITIALIZER;
pthread_mutex_t Scanner::nThreadsUploadMutex = PTHREAD_MUTEX_INITIALIZER;
pthread_mutex_t Scanner::nThreadsResultsMutex = PTHREAD_MUTEX_INITIALIZER;
unordered_map<string, Scanner::FileInfo> Scanner::filesProcessed; //Indexed by hash of file
unordered_set<string> Scanner::toBeProcessed;
int Scanner::threadsUploadRunning = 0;
int Scanner::threadsResultsRunning = 0;


void changeFileIcon(string path) {
	NSString *NSpath = [NSString stringWithUTF8String:path.c_str()];
	NSImage *infected = [NSImage imageNamed:@"infected.png"];
	NSImage *iconImage = [[NSWorkspace sharedWorkspace] iconForFile:NSpath];
	[iconImage setSize:NSMakeSize(256, 256)];
	
	[iconImage lockFocus];
	[infected drawInRect:NSMakeRect(0,0,256,256) fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:1.0];
	[iconImage unlockFocus];
	
	[[NSWorkspace sharedWorkspace] setIcon:iconImage forFile:NSpath options:0];
}

void Scanner::initialize(string workingDir) {
	CURLcode res = curl_global_init(CURL_GLOBAL_ALL);
	if(res != CURLE_OK) {
		fprintf(stderr, "curl_global_init() failed: %s\n", curl_easy_strerror(res));
		exit(-1);
	}
	
	if(db.open(workingDir+"/sf.db") == false)
		exit(-1);
	db.query("CREATE TABLE IF NOT EXISTS FILES("\
			 "PATH TEXT PRIMARY KEY NOT NULL,"\
			 "STATE TEXT NOT NULL,"\
			 "DATE TEXT NOT NULL,"\
			 "NEXT_CHECK TEXT,"\
			 "SCAN_RESULT TEXT,"\
			 "HASH TEXT,"\
			 "DATA_ID TEXT);", NULL);
	
	db.query("CREATE TABLE IF NOT EXISTS HASHES("\
			 "HASH TEXT PRIMARY KEY NOT NULL,"\
			 "SCAN_RESULT TEXT NOT NULL,"\
			 "DATA_ID TEXT NOT NULL);", NULL);
}

bool Scanner::connectivityIsOk() {
	CURL *curl;
	
	curl = curl_easy_init();
	if(curl) {
		curl_easy_setopt(curl, CURLOPT_URL, "https://api.metascan-online.com/");
		if(curl_easy_perform(curl) != CURLE_OK) {
			curl_easy_cleanup(curl);
			return false;
		}
	}
	
	curl_easy_cleanup(curl);
	
	return true;
}

void Scanner::loadDB() {
	struct stat info;
	FileInfo fileInfo;
	DBResults results;
	db.query("SELECT * FROM FILES", &results);
	
	vector<string> toBeErased;
	for(auto it = results.begin(); it != results.end(); it++) {
		int state = atoi((*it)["STATE"].c_str());
		string path = (*it)["PATH"];
		
		if( (state == SCANNING || state == SCANNED) //If it has really been processed
		   && lstat(path.c_str(), &info) == 0) { //If it still exists
			fileInfo.path = path;
			fileInfo.state = (ScanningState)state;
			fileInfo.date = atol((*it)["DATE"].c_str());
			fileInfo.nextResultsCheck = atol((*it)["NEXT_CHECK"].c_str());
			fileInfo.scanResult = atoi((*it)["SCAN_RESULT"].c_str());
			fileInfo.hash = (*it)["HASH"];
			fileInfo.data_id = (*it)["DATA_ID"];
			
			pthread_mutex_lock(&processedMutex);
			filesProcessed[path] = fileInfo;
			pthread_mutex_unlock(&processedMutex);
		}
		else
			toBeErased.push_back(path);
	}
	
	for(auto it = toBeErased.begin(); it != toBeErased.end(); it++)
		db.query("DELETE from FILES where PATH='"+ *it +"';", NULL);
	
	dbLoaded = true;
}

bool Scanner::saveChanges(FileInfo* file, bool insertion) {
	bool ok = true;
	
	pthread_mutex_lock(&processedMutex);
	if(insertion)
		filesProcessed[file->path] = *file;
	else {
		auto it = filesProcessed.find(file->path);
		if(it != filesProcessed.end()) //If it is already in the processed list, update
			it->second = *file;
		else
			ok = false;
	}
	pthread_mutex_unlock(&processedMutex);
	
	//SAVE TO BD
	if(ok) {
		ok = db.query("INSERT OR REPLACE INTO FILES(PATH, STATE, DATE, NEXT_CHECK, SCAN_RESULT, HASH, DATA_ID)"\
					  "VALUES("\
					  "'"+file->path+"',"\
					  "'"+to_string(file->state)+"',"\
					  "'"+to_string(file->date)+"',"\
					  "'"+to_string(file->nextResultsCheck)+"',"\
					  "'"+to_string(file->scanResult)+"',"\
					  "'"+file->hash+"',"\
					  "'"+file->data_id+"');", NULL);
		if(ok) {
			[appDelegate
			 performSelectorOnMainThread:@selector(shouldUpdateScanTable)
			 withObject:nil
			 waitUntilDone:NO];
		}
	}
	
	return ok;
}

void Scanner::setAPIKey(const char* key) {
	pthread_mutex_lock(&apiKeyMutex);
	apiKey = key;
	pthread_mutex_unlock(&apiKeyMutex);
	wrongApiKey = false;
}

string Scanner::getAPIKey() {
	string key;
	pthread_mutex_lock(&apiKeyMutex);
	key = apiKey;
	pthread_mutex_unlock(&apiKeyMutex);
	return key;
}

size_t curlNoOutput(char *ptr, size_t size, size_t nmemb, void *userdata){return size * nmemb;}

bool Scanner::isValidAPIKey(string key) {
	CURL *curl;
	CURLcode res;
	struct curl_slist* headerlist = NULL;
	string header;
	bool valid = false;
	
	//Set up headers
	header = "apikey: " + key;
	headerlist = curl_slist_append(headerlist, header.c_str());
	
	curl = curl_easy_init();
	if(curl) {
		curl_easy_setopt(curl, CURLOPT_URL, "https://api.metascan-online.com/v1/file/");
        curl_easy_setopt(curl, CURLOPT_HEADER, 1L);
		curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headerlist);
		curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, curlNoOutput);
		//curl_easy_setopt(curl, CURLOPT_VERBOSE, 1L);
		
		//Perform the request
		res = curl_easy_perform(curl);
		if(res != CURLE_OK) {
			fprintf(stderr, "curl_easy_perform() failed: %s\n", curl_easy_strerror(res));
			
			pthread_mutex_lock(&connectivityMutex);
			connectivity = false;
			pthread_mutex_unlock(&connectivityMutex);
			
			valid = true; //We can't tell whether it's correct or not
		}
		
		long http_code = 0;
		curl_easy_getinfo (curl, CURLINFO_RESPONSE_CODE, &http_code);
		if(http_code == 200 && res != CURLE_ABORTED_BY_CALLBACK) { //Succeeded
			valid = true;
		}
		else { //Failed
			if(http_code == 401)
				valid = false;
			else if(http_code == 403) {
				fprintf(stderr, "Exceeded usage, will wait 1h\n");
				exceededUsageTime = time(NULL);
				exceededUsage = true;
				valid = true; //We can't tell whether it's correct or not
			}
		}
		
	}
	
	curl_easy_cleanup(curl);
	
	return valid;
}

void Scanner::setRescanTime(long time) {
	pthread_mutex_lock(&rescanTimeMutex);
	rescanTime = time;
	pthread_mutex_unlock(&rescanTimeMutex);
}

void Scanner::getInfectedFiles(DBResults* infectedList) {
	db.query("SELECT * from FILES where SCAN_RESULT = '1' OR SCAN_RESULT = '2';", infectedList);
}

void Scanner::getAllFilesStatus(DBResults* filesStatus) {
	db.query("SELECT * from FILES ORDER BY STATE, SCAN_RESULT DESC, CAST(DATE AS INTEGER) DESC;", filesStatus);
}

size_t Scanner::initScanCallback(char *ptr, size_t size, size_t nmemb, void *userdata) {
	FileInfo fileInfo;
	string resp(ptr, ptr + size*nmemb);
	Json::Value root;
	Json::Reader reader;
	reader.parse(resp, root);
	
	if(root.isMember("data_id")) {
		string path((char*)userdata);
		string fileName = path.substr(path.find_last_of("/")+1);
		printf("File '%s' submitted for analisys, will check results in %d seconds\n",
			   fileName.c_str(),
			   MIN_CHECK_INTERVAL);
		
		//Change status
		fileInfo.path = path;
		fileInfo.state = SCANNING;
		fileInfo.date = time(NULL);
		fileInfo.nextResultsCheck = time(NULL) + MIN_CHECK_INTERVAL;
		fileInfo.hash = "";
		fileInfo.data_id = root["data_id"].asString();
		saveChanges(&fileInfo);
	}
	
	return size*nmemb;
}

struct SendFileCllbckStruct {
    FILE* fd;
    string path;
};
size_t Scanner::sendFileCallback(void *ptr, size_t size, size_t nmemb, void *userp) {
	SendFileCllbckStruct* fileStruct = (SendFileCllbckStruct*)userp;
	size_t bytes;
    bool exit = false;
	
    if(size*nmemb < 1)
		exit = true;
    
    pthread_mutex_lock(&processedMutex);
    if(filesProcessed.find(fileStruct->path) == filesProcessed.end()) //File doesn't exist anymore
        exit = true; //To avoid locking the file
    pthread_mutex_unlock(&processedMutex);

	if(exit == true) {
		fclose(fileStruct->fd);
		return 0;
	}
	
	bytes = fread(ptr, 1, size*nmemb, fileStruct->fd);
	if(bytes < 1)
		fclose(fileStruct->fd);
	
	return bytes;
}

void* Scanner::workerThread(void* _file) {
	CURL* curl;
	CURLcode res;
	struct curl_slist* headerlist = NULL;
	string* file = (string*)_file;
	string header;
	SendFileCllbckStruct fileStruct;
	size_t fileSize;
	
    fileStruct.path = *file;
	fileStruct.fd = fopen(file->c_str(), "r");
	if(!fileStruct.fd) {
		fprintf(stderr, "Error opening %s\n", file->c_str());
		return NULL;
	}
	//Get the file size
	fseek(fileStruct.fd, 0, SEEK_END);
	fileSize = ftell(fileStruct.fd);
	rewind(fileStruct.fd);
	
	//Set up headers
	header = "apikey: " + getAPIKey();
	headerlist = curl_slist_append(headerlist, header.c_str());
	header = "filename: " + file->substr(file->find_last_of("/")+1);
	headerlist = curl_slist_append(headerlist, header.c_str());
	
	curl = curl_easy_init();
	if(curl) {
		curl_easy_setopt(curl, CURLOPT_URL, "https://api.metascan-online.com/v1/file");
		curl_easy_setopt(curl, CURLOPT_POST, 1L);
        curl_easy_setopt(curl, CURLOPT_HEADER, 1L);
		curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headerlist);
		curl_easy_setopt(curl, CURLOPT_READFUNCTION, &Scanner::sendFileCallback);
		curl_easy_setopt(curl, CURLOPT_READDATA, &fileStruct);
		curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE_LARGE, fileSize);
        curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, &Scanner::initScanCallback);
		curl_easy_setopt(curl, CURLOPT_WRITEDATA, file->c_str());
		//curl_easy_setopt(curl, CURLOPT_VERBOSE, 1L);
		
		//Perform the request
		res = curl_easy_perform(curl);
		if(res != CURLE_OK) {
			fprintf(stderr, "curl_easy_perform() failed: %s\n", curl_easy_strerror(res));
			
			pthread_mutex_lock(&connectivityMutex);
			connectivity = false;
			pthread_mutex_unlock(&connectivityMutex);
		}
		
		long http_code = 0;
		curl_easy_getinfo (curl, CURLINFO_RESPONSE_CODE, &http_code);
		if(http_code == 200 && res != CURLE_ABORTED_BY_CALLBACK) { //Succeeded
			//printf("File %s uploaded\n", file->c_str());
		}
		else { //Failed
			pthread_mutex_lock(&apiKeyMutex);
			if(http_code == 401 && wrongApiKey == false) {
				fprintf(stderr, "API Key invalid\n");
				wrongApiKey = true;
				[appDelegate
				 performSelectorOnMainThread:@selector(wrongKeyAlert)
				 withObject:nil
				 waitUntilDone:NO];
			}
			pthread_mutex_unlock(&apiKeyMutex);
			
			if(http_code == 403) {
				fprintf(stderr, "Exceeded usage, will wait 1h\n");
				exceededUsageTime = time(NULL);
				exceededUsage = true;
			}
			
			sleep(2);
			
			pthread_mutex_lock(&processedMutex);
			filesProcessed.erase(*file);
			pthread_mutex_unlock(&processedMutex);
			
			//Put it again in the queue
			pthread_mutex_lock(&toBeProcessedMutex);
			toBeProcessed.insert(*file);
			pthread_mutex_unlock(&toBeProcessedMutex);
		}
		
		curl_easy_cleanup(curl);
	}
	
	delete file;
	
	pthread_mutex_lock(&nThreadsUploadMutex);
	threadsUploadRunning--;
	pthread_mutex_unlock(&nThreadsUploadMutex);
	
	return NULL;
}

bool Scanner::sendFileToScan(string file) {
	FileInfo fileInfo;
	pthread_t thread;
	pthread_attr_t attr;
	int error;
	bool canBeProcessedNow = false;
	
	if(wrongApiKey == false && threadsUploadRunning < MAX_UPLOAD_THREADS) {
		//Add to processed files
		fileInfo.path = file;
		fileInfo.state = SENDING;
		fileInfo.date = time(NULL);
		fileInfo.hash = "";
		fileInfo.data_id = "";
		saveChanges(&fileInfo, true);
		
		//Create thread
		pthread_attr_init(&attr);
		pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
		error = pthread_create(&thread, &attr, &Scanner::workerThread, (void*)new string(file));
		pthread_attr_destroy(&attr);
		if(error != 0) {
			fprintf(stderr, "Cannot create scanner thread\n");
			
			pthread_mutex_lock(&processedMutex);
			filesProcessed.erase(file);
			pthread_mutex_unlock(&processedMutex);
		}
		else {
			pthread_mutex_lock(&nThreadsUploadMutex);
			threadsUploadRunning++;
			pthread_mutex_unlock(&nThreadsUploadMutex);
			canBeProcessedNow = true;
		}
	}
	
	return canBeProcessedNow;
}

size_t Scanner::getResultsCallback(char *ptr, size_t size, size_t nmemb, void *userdata) {
	FileInfo fileInfo;
	ResultsJSON* results = (ResultsJSON*)userdata;
	string resp(ptr, ptr + size*nmemb);
	Json::Value root;
	
	if(results->reader.parse(resp, root)) {
		//Get scan results
		string fileName = results->path.substr(results->path.find_last_of("/")+1);
		int progress = root["scan_results"]["progress_percentage"].asInt();
		long elapsedTime;
		long estimatedTotalTime;
		long nextCheckTime;
		string scanResultA = root["scan_results"]["scan_all_result_a"].asString();
		int scanResultI = root["scan_results"]["scan_all_result_i"].asInt();
		
		time_t now = time(NULL);
		elapsedTime = difftime(now, results->dateSubmitted);
		if(progress > 0)
			estimatedTotalTime = (elapsedTime/(progress/100.0))*1.1;
		else
			estimatedTotalTime = elapsedTime + (MIN_CHECK_INTERVAL+MAX_CHECK_INTERVAL)/2;
		nextCheckTime = estimatedTotalTime - elapsedTime;
		if(nextCheckTime < MIN_CHECK_INTERVAL) nextCheckTime = MIN_CHECK_INTERVAL;
		else if(nextCheckTime > MAX_CHECK_INTERVAL) nextCheckTime = MAX_CHECK_INTERVAL;
		
		printf("Results for file '%s' checked, scan progress: %d%%\n", fileName.c_str(), progress);
		printf("Elapsed: %ld, estimated: %ld\n", elapsedTime, estimatedTotalTime);
		
		//Change status
		fileInfo.path = results->path;
		fileInfo.hash = root["file_info"]["sha1"].asString();
		fileInfo.data_id = results->data_id;
		if(progress == 100) {
			printf("File is: %s\n", scanResultA.c_str());
			fileInfo.state = SCANNED;
			fileInfo.date = now;
			fileInfo.scanResult = scanResultI;
			if(scanResultI == 1 || scanResultI == 2 || scanResultI == 4
			   || scanResultI == 6 || scanResultI == 8) { //Threat
				notifyUser(results->path, scanResultI);
				if(scanResultI != 2) //Only if we are sure it's infected
					changeFileIcon(results->path);
			}
			db.query("INSERT OR REPLACE INTO HASHES(HASH, SCAN_RESULT, DATA_ID)"\
					 "VALUES("\
					 "'"+fileInfo.hash+"',"\
					 "'"+to_string(fileInfo.scanResult)+"',"\
					 "'"+fileInfo.data_id+"');", NULL);
		}
		else {
			printf("Next check in: %ld\n", nextCheckTime);
			fileInfo.state = SCANNING;
			fileInfo.date = results->dateSubmitted;
			fileInfo.nextResultsCheck = now + nextCheckTime;
		}
		saveChanges(&fileInfo);
	}
	
	return size*nmemb;
}

void* Scanner::resultsThread(void* _results) {
	ResultsJSON* results = (ResultsJSON*)_results;
	CURL* curl;
	CURLcode res;
	struct curl_slist* headerlist = NULL;
	string header;
	string url = "https://api.metascan-online.com/v1/file/" + results->data_id;
	
	//Set up headers
	header = "apikey: " + getAPIKey();
	headerlist = curl_slist_append(headerlist, header.c_str());
	
	curl = curl_easy_init();
	if(curl) {
		curl_easy_setopt(curl, CURLOPT_URL, url.c_str());
		curl_easy_setopt(curl, CURLOPT_POST, 0L); //GET
        curl_easy_setopt(curl, CURLOPT_HEADER, 1L);
		curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headerlist);
        curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, &Scanner::getResultsCallback);
		curl_easy_setopt(curl, CURLOPT_WRITEDATA, results);
		//curl_easy_setopt(curl, CURLOPT_VERBOSE, 1L);
		
		//Perform the request
		res = curl_easy_perform(curl);
		if(res != CURLE_OK) {
			fprintf(stderr, "curl_easy_perform() failed: %s\n", curl_easy_strerror(res));
			
			pthread_mutex_lock(&connectivityMutex);
			connectivity = false;
			pthread_mutex_unlock(&connectivityMutex);
		}
		
		long http_code = 0;
		curl_easy_getinfo (curl, CURLINFO_RESPONSE_CODE, &http_code);
		if(http_code == 200 && res != CURLE_ABORTED_BY_CALLBACK) { //Succeeded
			
		}
		else { //Failed
			pthread_mutex_lock(&apiKeyMutex);
			if(http_code == 401 && wrongApiKey == false) {
				fprintf(stderr, "API Key invalid\n");
				wrongApiKey = true;
				[appDelegate
				 performSelectorOnMainThread:@selector(wrongKeyAlert)
				 withObject:nil
				 waitUntilDone:NO];
			}
			pthread_mutex_unlock(&apiKeyMutex);
			
			if(http_code == 403) {
				fprintf(stderr, "Exceeded usage, will wait 1h\n");
				exceededUsageTime = time(NULL);
				exceededUsage = true;
			}
		}
		
		curl_easy_cleanup(curl);
	}
	
	delete results;
	
	pthread_mutex_lock(&nThreadsUploadMutex);
	threadsResultsRunning--;
	pthread_mutex_unlock(&nThreadsUploadMutex);
	
	return NULL;
}

bool Scanner::getResults(ResultsJSON* res) {
	pthread_t thread;
	pthread_attr_t attr;
	int error;
	bool canBeProcessedNow = false;
	
	if(wrongApiKey == false && threadsResultsRunning < MAX_RESULTS_THREADS) {
		//Create thread
		pthread_attr_init(&attr);
		pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
		error = pthread_create(&thread, &attr, &Scanner::resultsThread, (void*)res);
		pthread_attr_destroy(&attr);
		if(error != 0) {
			fprintf(stderr, "Cannot create scanner thread\n");
			
		}
		else {
			pthread_mutex_lock(&nThreadsResultsMutex);
			threadsResultsRunning++;
			pthread_mutex_unlock(&nThreadsResultsMutex);
			canBeProcessedNow = true;
		}
	}
	
	return canBeProcessedNow;
}

void Scanner::notifyUser(string file, int scanResult) {
	string fileName = file.substr(file.find_last_of("/")+1);
	CNUserNotification *notification = [CNUserNotification new];
	notification.title = @"Threat found!";
	if(scanResult == 1)
		notification.subtitle = [NSString stringWithUTF8String:("File '" + fileName + "' is infected!").c_str()];
	else if(scanResult == 2)
		notification.subtitle = [NSString stringWithUTF8String:("File '" + fileName + "' is suspicious!").c_str()];
	notification.informativeText = @"Click to see details";
	notification.hasActionButton = NO;
	notification.feature.dismissDelayTime = 9999;
	notification.feature.bannerImage = [NSApp applicationIconImage];
	notification.soundName = CNUserNotificationDefaultSound;
	notification.userInfo = @{ @"notificationType": @"infected" };
	[appDelegate
	 performSelectorOnMainThread:@selector(notifyUser:)
	 withObject:notification
	 waitUntilDone:NO];
}

void* Scanner::startScanning(void* _path) {
	loadDB();
	
	for(;;) {
		bool workToDo = false;
		string file;
		
		sleep(1);
		
		while(!connectivity && !finish) {
			sleep(1);
			
			pthread_mutex_lock(&connectivityMutex);
			connectivity = connectivityIsOk();
			pthread_mutex_unlock(&connectivityMutex);
			
			if(connectivity)
				printf("Recovered connectivity\n");
		}
		
		while(wrongApiKey && !finish) sleep(1);
		
		if(exceededUsage) {
			while(exceededUsageTime + 65*60 < time(NULL) && !finish) //65min
				sleep(1);
			exceededUsage = false;
		}
		
		if(finish) break;
		
		//Process files//
		pthread_mutex_lock(&toBeProcessedMutex);
		auto itTBP = toBeProcessed.begin();
		if(itTBP != toBeProcessed.end()) {
			workToDo = true;
			file = *itTBP;
		}
		pthread_mutex_unlock(&toBeProcessedMutex);
		
		if(workToDo) {
			//SCAN FILE
			if(sendFileToScan(file)) {
				//Get it out of the queue
				pthread_mutex_lock(&toBeProcessedMutex);
				toBeProcessed.erase(file);
				pthread_mutex_unlock(&toBeProcessedMutex);
				
				printf("Uploading %s to scan\n", file.c_str());
			}
		}
		
		
		//Check processed files results//
		FileInfo fileInfo;
		workToDo = false;
		time_t now = time(NULL);
		
		pthread_mutex_lock(&processedMutex);
		auto itFP = filesProcessed.begin();
		while(itFP != filesProcessed.end() && workToDo == false) {
			if(itFP->second.state == SCANNING
			   && difftime(now, itFP->second.nextResultsCheck) >= 0) {
				//Just in case something goes wrong with the checking thread, we add a recheck in the future
				itFP->second.nextResultsCheck = itFP->second.date + MAX_CHECK_INTERVAL;
				fileInfo = itFP->second;
				workToDo = true;
			}
			else itFP++;
		}
		pthread_mutex_unlock(&processedMutex);
		
		if(workToDo) {
			ResultsJSON* res = new ResultsJSON;
			res->path = fileInfo.path;
			res->data_id = fileInfo.data_id;
			res->dateSubmitted = fileInfo.date;
			if(getResults(res)) {
				printf("Checking results of %s, data_id '%s'\n", fileInfo.path.c_str(), fileInfo.data_id.c_str());
			}
			else { //Already too many threads checking results, try again later
				pthread_mutex_lock(&processedMutex);
                auto itFP = filesProcessed.find(fileInfo.path);
                if(itFP != filesProcessed.end())
                    itFP->second.nextResultsCheck = now + 5;
				pthread_mutex_unlock(&processedMutex);
			}
		}
		
		//Check if it's the time to rescan some file
		pthread_mutex_lock(&rescanTimeMutex);
		long _rescanTime = rescanTime;
		pthread_mutex_unlock(&rescanTimeMutex);
		
		if(_rescanTime > 0) {
			vector<string> toBeRescanned;
			pthread_mutex_lock(&processedMutex);
			for(auto itFP = filesProcessed.begin(); itFP != filesProcessed.end(); itFP++) {
				if(itFP->second.state == SCANNED
				   && itFP->second.scanResult != 1 && itFP->second.scanResult != 2 //Only rescans if it wasn't infected
				   && now >= itFP->second.date + _rescanTime) {
					itFP->second.state = NOT_SCANNED;
					toBeRescanned.push_back(itFP->second.path);
				}
			}
			pthread_mutex_unlock(&processedMutex);
			
			for(auto it = toBeRescanned.begin(); it != toBeRescanned.end(); it++) {
				pthread_mutex_lock(&toBeProcessedMutex);
				toBeProcessed.insert(*it);
				pthread_mutex_unlock(&toBeProcessedMutex);
			}
		}
	}
	
	printf("Finishing scanner thread...\n");
	finish = false;
	dbLoaded = false;
	return NULL;
}

void Scanner::scanFile(string file) {
	bool scan = true;
	
	while(dbLoaded == false) sleep(1);
	
	CFStringRef path = CFStringCreateWithBytes(NULL, (const unsigned char*)file.c_str(), file.length(), kCFStringEncodingUTF8, false);
	string hash = FileSHA1HashCreateWithPath(path, 0);
	
	printf("Hash: %s\n", hash.c_str());
	
	pthread_mutex_lock(&processedMutex);
	auto it = filesProcessed.find(file);
	//It has already been processed AND hasn't been modified
	if(it != filesProcessed.end() && it->second.hash == hash)
		scan = false;
	pthread_mutex_unlock(&processedMutex);
	
	if(scan) {
		DBResults results;
		db.query("SELECT * from HASHES where HASH = '"+hash+"';", &results);
		if(results.size()) {
			FileInfo fileInfo;
			fileInfo.path = file;
			fileInfo.state = SCANNED;
			fileInfo.date = time(NULL);
			fileInfo.nextResultsCheck = -1;
			fileInfo.scanResult = atoi(results[0]["SCAN_RESULT"].c_str());
			fileInfo.hash = hash;
			fileInfo.data_id = results[0]["DATA_ID"];
			saveChanges(&fileInfo, true);
			scan = false;
			printf("File '%s' recognized as already processed\n", file.c_str());
		}
	}
	
	if(scan) {
		pthread_mutex_lock(&toBeProcessedMutex);
		toBeProcessed.insert(file);
		pthread_mutex_unlock(&toBeProcessedMutex);
	}
}

void Scanner::fileDeleted(string file) {
	pthread_mutex_lock(&toBeProcessedMutex);
	toBeProcessed.erase(file);
	pthread_mutex_unlock(&toBeProcessedMutex);
	
	pthread_mutex_lock(&processedMutex);
    filesProcessed.erase(file);
    pthread_mutex_unlock(&processedMutex);
    
    //Delete entry
	db.query("DELETE from FILES where PATH = '"+file+"';", NULL);
	
	[appDelegate
	 performSelectorOnMainThread:@selector(shouldUpdateScanTable)
	 withObject:nil
	 waitUntilDone:NO];
}
