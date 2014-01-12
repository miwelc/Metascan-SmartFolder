//
//  DB.cpp
//  SmartFolder
//
//  Created by Miguel Cantón Cortés on 02/11/13.
//  Copyright (c) 2013 Miguel Cantón Cortés. All rights reserved.
//

#include "DB.h"

DB::DB() {
	db = 0;
}

DB::~DB() {
	close();
}

bool DB::open(string path) {
	close();
	
	if(sqlite3_open(path.c_str(), &db) != SQLITE_OK) {
		printf("Can't open database: %s\n", sqlite3_errmsg(db));
		return false;
	}
	else {
		printf("Opened database successfully\n");
		return true;
	}
}

void DB::close() {
	if(db)
		sqlite3_close(db);
	db = 0;
}

bool DB::query(string query, DBResults* results) {
	sqlite3_stmt *statement;
	
	if(results)
		results->clear();
	
    if(sqlite3_prepare_v2(db, query.c_str(), -1, &statement, NULL) != SQLITE_OK) {
        fprintf(stderr, "Error when preparing query!\n");
        fprintf(stderr, "Query was: '%s'\n", query.c_str());
		return false;
    }
	
	while(sqlite3_step(statement) == SQLITE_ROW) {
		DBRow row;
		
		for(int i = 0; i < sqlite3_column_count(statement); i++) {
			const char* name = sqlite3_column_name(statement, i);
			const unsigned char* value = sqlite3_column_text(statement, i);
			if(value) row[name] = (const char*)value;
			else row[name] = "";
		}
		
		if(results)
			results->push_back(row);
	}
	
	return sqlite3_finalize(statement) == SQLITE_OK;
}



