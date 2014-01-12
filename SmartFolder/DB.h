//
//  DB.h
//  SmartFolder
//
//  Created by Miguel Cantón Cortés on 02/11/13.
//  Copyright (c) 2013 Miguel Cantón Cortés. All rights reserved.
//

#ifndef __SmartFolder__DB__
#define __SmartFolder__DB__

#include <stdlib.h>
#include <stdio.h>
#include <sqlite3.h>
#include <string>
#include <unordered_map>
#include <vector>

using namespace std;

typedef unordered_map<string, string> DBRow;
typedef vector<DBRow> DBResults;

class DB {
	private:
		sqlite3 *db;
		
	public:
		DB();
		~DB();
		bool open(string path);
		void close();
		bool query(string query, DBResults* results);
};

#endif /* defined(__SmartFolder__DB__) */
