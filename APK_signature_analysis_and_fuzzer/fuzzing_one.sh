#!/system/bin/sh


## WHEN NOT RUN OVER ADB (for example over termux)
#!/bin/bash


## output colors ##
RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
NC='\033[0m'

# help option
Help()
{
   # Display Help
   echo "Syntax: ./fuzzing_one <method-chosen> <time-to-fuzz> <input-dir> <output-dir> <read-from-file[0|1]> <AFL_DEBUG[0|1]> <parallel-fuzzing[0|1]>" 
   echo
   echo "Fuzz given native method"
   echo
   echo "Options:"
   echo "   -h, --help     Print this Help."
   echo "	<method-chosen>: method chosen from *analyze_native_signatures.sh* script, as fuzzing target"
   echo "	<time-to-fuzz>: time to fuzz each method for, as float[s|m|h|d] (s=seconds, m=minutes, h=hours, d=days)"
   echo "	<input-dir>: fuzzing input directory name, populated with meaningful seeds"
   echo "	<output-dir>: fuzzing output directory name"
   echo "	<read-from-file>: flag to specify if fuzzer will read from file or from stdin (depending on how harness is implemented)"
   echo "	<AFL_DEBUG[0|1]>: set if you want to debug AFL++"
   echo "	<parallel-fuzzing[0...#max_cores]>: set if you want to run parallel fuzzing campaigns on all available cores"

   echo
}

PATH_TO_HOME="/data/data/com.termux/files/home/"
AFL_DIR="AFLplusplus-AndroidPatches"
PATH_TO_TERMUX_BIN="/data/data/com.termux/files/usr/bin"
HARNESS_DIR="APK_signature_analysis_and_fuzzer"
TARGET_APK="target_APK/"
PATH_TO_AFL=$PATH_TO_HOME$AFL_DIR


Fuzz()
{
	# arguments
	METHOD=$1
	TIME_TO_FUZZ=$2
	FUZZ_INPUT_DIR=$3
	FUZZ_OUTPUT_DIR=$4
	READ_FROM_FILE=$5
	AFL_DEBUG_FLAG=$6
	PARALLEL_FUZZING=$7

	# add AFL++ to path
	export PATH=$PATH_TO_AFL:$PATH_TO_TERMUX_BIN:$PATH
	
	# compile harness
	export LD_PRELOAD="$PATH_TO_AFL/libLLVM-13.so"
	echo -e "${GREEN}[LOG]${NC} Compiling harness" 
	afl-clang++ --afl-classic -Wall -std=c++17 -Wl,--export-dynamic harness.cpp -o harness
	unset LD_PRELOAD

	# set AFL_DEBUG if needed
	if [ "$AFL_DEBUG_FLAG" = "1" ] ; then
		export AFL_DEBUG=1
	fi

	# set up number cores
	NUM_CORES=$(nproc --all)
	if [ $PARALLEL_FUZZING -lt $NUM_CORES ] ; then
		NUM_CORES=$PARALLEL_FUZZING
	fi

	FUZZ_ERROR=""

	# extract single app name and methods name
	LINE=$(	grep -r --color -w --include "signatures_pattern.txt" -F "$METHOD" "$TARGET_APK")
	APP_PATH=$(echo $LINE | cut -d: -f1 | sed "s/signatures_pattern.txt//g")
	APP=$(echo $APP_PATH | cut -d/ -f2)

	echo -e "${GREEN}[LOG]${NC} Fuzzing $APP - $METHOD" 

	# create fuzzer output sub-directory for app
	mkdir -p "$FUZZ_OUTPUT_DIR/$APP:$METHOD"

	# fuzz
	export LD_PRELOAD="/data/data/com.termux/files/usr/lib/libc++_shared.so"
	export LD_LIBRARY_PATH="/apex/com.android.art/lib64:$(pwd)/$APP_PATH/lib/arm64-v8a:/system/lib64"
	cd fuzz_dir
	if [ $PARALLEL_FUZZING -gt 0 ] ; then
		for IDX in $(seq 1 $NUM_CORES) ; do
			echo -e "${GREEN}[LOG]${NC} Starting fuzzer on core #$IDX\n"
			if [ "$READ_FROM_FILE" = "1" ] ; then
				# fuzzer feed input trough file
				if [ $IDX -eq 1 ] ; then
					nohup timeout $TIME_TO_FUZZ afl-fuzz -i "../$FUZZ_INPUT_DIR" -o "../$FUZZ_OUTPUT_DIR/$APP:$METHOD" -M "Master" -- ./../harness "$(pwd)/../$APP_PATH" $METHOD @@  > /dev/null &
				else
					nohup timeout $TIME_TO_FUZZ afl-fuzz -i "../$FUZZ_INPUT_DIR" -o "../$FUZZ_OUTPUT_DIR/$APP:$METHOD" -S "Slave_$IDX" -- ./../harness "$(pwd)/../$APP_PATH" $METHOD @@  > /dev/null &
				fi

				# in this case can't check if fuzzing was successful as both nohup and AFL++_failing return 0
				if [ $IDX -eq 1 ] ; then
					echo -e "${GREEN}[LOG]${NC} Done fuzzing $APP\n"
				fi
			else
				# fuzzer feed input through stdin
				if [ $IDX -eq 1 ] ; then
					nohup timeout $TIME_TO_FUZZ afl-fuzz -i "../$FUZZ_INPUT_DIR" -o "../$FUZZ_OUTPUT_DIR/$APP:$METHOD" -M "Master" -- ./../harness "$(pwd)/../$APP_PATH" $METHOD  > /dev/null &
				else
					nohup timeout $TIME_TO_FUZZ afl-fuzz -i "../$FUZZ_INPUT_DIR" -o "../$FUZZ_OUTPUT_DIR/$APP:$METHOD" -S "Slave_$IDX" -- ./../harness "$(pwd)/../$APP_PATH" $METHOD  > /dev/null &
				fi
		
				# in this case can't check if fuzzing was successful as both nohup and AFL++_failing return 0
				if [ $IDX -eq 1 ] ; then
					echo -e "${GREEN}[LOG]${NC} Done fuzzing $APP\n"
				fi
			fi
		done
	else
		if [ "$READ_FROM_FILE" = "1" ] ; then
			# fuzzer feed input trough file
			timeout $TIME_TO_FUZZ afl-fuzz -i "../$FUZZ_INPUT_DIR" -o "../$FUZZ_OUTPUT_DIR/$APP:$METHOD" -- ./../harness "$(pwd)/../$APP_PATH" $METHOD @@

			# check if fuzzer was able to fuzz
			STATUS=$?
			if [ $STATUS -ne 124 ] ; then
				echo -e "${RED}[ERR]${NC} Fuzzer unable to fuzz $APP\n"
				FUZZ_ERROR+="	$APP - $METHOD\n"
			else
				echo -e "${GREEN}[LOG]${NC} Done fuzzing $APP\n"
			fi
		else
			# fuzzer feed input through stdin
			timeout $TIME_TO_FUZZ afl-fuzz -i "../$FUZZ_INPUT_DIR" -o "../$FUZZ_OUTPUT_DIR/$APP:$METHOD" -- ./../harness "$(pwd)/../$APP_PATH" $METHOD

			# check if fuzzer was able to fuzz
			STATUS=$?
			if [ $STATUS -ne 124 ] ; then
				echo -e "${RED}[ERR]${NC} Fuzzer unable to fuzz $APP\n"
				FUZZ_ERROR+="	$APP - $METHOD\n"
			else
				echo -e "${GREEN}[LOG]${NC} Done fuzzing $APP\n"
			fi
		fi
	fi
	cd ..
		

	if [ -n "$FUZZ_ERROR" ] ; then
		echo -e "${RED}[ERR]${NC} Couldn't fuzz the following apps: "
		echo -e "$FUZZ_ERROR"
	fi

	# calculate stats
	NUM_ALL_APPS=$(wc -l < fuzzing_target_apps.txt)
	NUM_ERR_APPS=$(echo -e "$FUZZ_ERROR" | wc -l)
	NUM_ERR_APPS=$((NUM_ERR_APPS-1))
	NUM_FUZZ_APPS=$((NUM_ALL_APPS-NUM_ERR_APPS))
	
	echo -e "${GREEN}[LOG]${NC} All done"
	echo -e "	- find output in $FUZZ_OUTPUT_DIR directory"
	echo -e "	- fuzzed $NUM_FUZZ_APPS / $NUM_ALL_APPS"
}

# Main
if [ "$#" -eq 0 ] ; then
    echo "Try './fuzzing_one.sh --help' for more information."
    exit 1
elif [ "$1" == "-h" ] || [ "$1" == "--help" ]; then
    Help
    exit 0
elif [ "$#" -ne 7 ] ; then
    echo "Error usage..."
    Help
    exit 1
else
    Fuzz $1 $2 $3 $4 $5 $6 $7
    exit 0
fi
