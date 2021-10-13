#!/bin/bash
TIME_START=$(date +%s)

set -e

#################
# CONFIGURATION #
#################

# Feel free to adjust these to your likings

APP_NAME='The Butcher'
APP_AUTHOR='Federico Mantovani'
VERSION='1.0.2'
TMP_DIR='tmp'
FILENAME_SUFFIX='butchered'
DEFAULT_SOURCE='./data'
DEFAULT_OUTDIR='./butchered'
DEFAULT_CLI_FILTERS='removesilence' # Comma-separated, just like argument
DEFAULT_INT_RS='Yes'                # Remove silence
DEFAULT_INT_NORM='No'               # Normalize volume
DEFAULT_INT_AF='No'                 # Audio filters
DEFAULT_SAVE_INTERM='No'            # Save intermediate files
FFMPEG_FRONTEND=ffpb                # What command to use for ffmpeg commands (e.g. ffpb)

#################

#############
# FUNCTIONS #
#############

# USAGE

prog_name=$0

usage() {
	echo "$APP_NAME HELP"
	echo ""
	echo "Usage: $prog_name [<options>] source [outdir]"
	echo ""
	echo "ARGUMENTS"
	echo "	source              Source file/directory"
	echo "	outdir              Output directory (same as source directory if omitted)"
	echo ""
	echo "OPTIONS"
	echo "	-h --help           Display this help message"
	echo "	-v --version        Display the program version"
	echo "	-i --interactive    Run program interactively. Other options will be ignored"
	echo "	-d --install-deps   Automatically try to install missing dependencies"
	echo "	-n --norecurse      Do not recursively look for files in <source> if it is a directory"
	echo "	-c --create-outdir  Create output directory if it does not exist yet"
	echo "	-o --options <option1>,...,<optionN>"
	echo "	                    Sets the list of enabled options. Possible values are:"
	echo "	                    - 'r', 'removesilence':     Cuts out silent parts of video"
	echo "	                    - 'n', 'normalize':         Normalizes audio volume"
	echo "	                    - 'a', 'audiofilters':      Applies small enhancements to audio"
	echo "	                                                (bandpass, reduce clicking, reduce clipping)"
	echo "	                    The following options are enabled by default: 'removesilence'"
	echo "	-r --dry-run		Only show commands but do not execute them"
	echo "	-s --save-interm    If enabled, intermediate results will be persisted as output files in"
	echo "	                    case of failure of a pass. If a pass succeeds, the intermediate file will"
	echo "	                    be overwritten. If all passes succeed, only the final output is persisted."
	echo "	                    Warning: this option may incur additional copying of large files."
	echo ""
	echo "	Every option must be given separately."
	echo ""
	echo "AUTHOR"
	echo "	Federico Mantovani <fmantova@student.ethz.ch>"
	echo ""
	echo "LICENSE"
	echo "	MIT License, Copyright (c) 2021 Federico Mantovani"
}

# VERSION

version() {
	echo $VERSION
}

# HELPER

convert_seconds() {
	local secs=${1%.*}
	printf '%02dh %02dm %02ds\n' $((secs / 3600)) $((secs % 3600 / 60)) $((secs % 60))
}

video_duration() {
	local x=$(ffprobe -i $1 -show_entries format=duration -v quiet -of csv="p=0")
	echo "${x%.*}"
}

check_requirement() {
	# $1: command
	# $2-n: installation commands
	if ! command -v $1 &>/dev/null; then
		if $interactive; then
			# Running in interactive mode
			echo "Missing dependency: $1 - Please install before proceeding"
			read -p "Install now? (y/n) " install
			if [[ $install =~ [Yy].* ]]; then
				for cmd in "${@:2}"; do # Process all arguments except first
					eval $cmd
				done
			else
				echo "This program can't run without $1. Please install manually and try again."
				exit 1
			fi
		else
			# Running in static mode
			if ${opts['install-deps']}; then
				for cmd in "${@:2}"; do
					eval $cmd
				done
			else
				echo "This program can't run without $1. Please install manually and try again."
				exit 1
			fi
		fi
	fi
}

filename_append() {
	# $1: Original filename
	# $2: Base source directory
	# $3: Base output directory
	# $4: String to append
	local base="${1#$2'/'}"
	local name="${base%%.*}"
	local ext="${base##*.}"
	echo "$3/${name}_$4.$ext"
}

tmp_filename() {
	# $1: Real filename
	# $2: Suffix length
	local base=$(basename $1)
	local name="${base%%.*}"
	local ext="${base##*.}"
	local len=$([ -z $2 ] && echo 20 || echo "$2")
	local rand=$(echo $RANDOM | md5sum | head -c $len)
	echo "$TMP_DIR/${name}_$rand.$ext"
}

cleanup() {
	# Remove temporary files
	if [ -d $TMP_DIR ]; then
		rm -r $TMP_DIR
	fi
}

trap cleanup EXIT

# PROGRAM LOGIC

check_requirements() {
	# Requirements
	echo "Checking requirements..."

	check_requirement "ffmpeg" \
		"sudo apt update" \
		"sudo apt install ffmpeg -y"

	check_requirement "figlet" \
		"sudo apt update" \
		"sudo apt install figlet -y"

	check_requirement "python3" \
		"sudo apt update" \
		"sudo apt install software-properties-common -y" \
		"sudo add-apt-repository ppa:deadsnakes/ppa" \
		"sudo apt update" \
		"sudo apt install python3 -y"

	check_requirement "pip3" \
		"python3 -m ensurepip --upgrade || sudo apt install python3-pip -y"

	check_requirement "jumpcutter" \
		"pip3 install jumpcutter"

	check_requirement "ffpb" \
		"pip3 install ffpb"

	echo "All requirements met."
}

set_input_files() {
	# Input files
	if $interactive; then
		read -e -p "Source file/directory (default: '$DEFAULT_SOURCE/'): " src
		if [ -z $src ]; then
			src=$DEFAULT_SOURCE
		fi
		src=${src%/} # Trim trailing slash
	else
		src=${posargs[0]%/} # Files argument is first positional argument
	fi
	if [ -f $src ]; then
		files=$src # Just a single file
		indir=$(dirname $src)
	elif [ -d $src ]; then
		if $interactive; then
			default_recurse_subdirs='Yes'
			read -p "Scan files in subdirectories? (y/n, default: $default_recurse_subdirs) " recurse_subdirs
			if [ -z $recurse_subdirs ]; then
				recurse_subdirs=$default_recurse_subdirs
			fi
		else
			if ${opts['no-recurse']}; then
				recurse_subdirs='n'
			else
				recurse_subdirs='y'
			fi
		fi
		if [[ $recurse_subdirs =~ [Yy].* ]]; then
			files=$(find $src -type f -exec file -N -i -- {} + | sed -n 's!: video/[^:]*$!!p')
		else
			files=$(find $src -maxdepth 1 -type f -exec file -N -i -- {} + | sed -n 's!: video/[^:]*$!!p')
		fi
		indir=$src
	else
		echo "ERROR: '$src' is not a file or directory, aborting..."
		exit 1
	fi
}

set_output_dir() {
	# Output directory
	if $interactive; then
		read -e -p "Output directory (default: '$DEFAULT_OUTDIR/'): " outdir
		if [ -z "$outdir" ]; then
			outdir=$DEFAULT_OUTDIR
		fi
	else
		if [ -z ${posargs[1]} ]; then
			outdir=$DEFAULT_OUTDIR
		else
			outdir=${posargs[1]} # Out directory is second positional argument
		fi
	fi
	outdir=${outdir%/} # Trim trailing slash
	if [ ! -d $outdir ]; then
		if $interactive; then
			read -p "Output directory does not exist. Create now? (y/n) " create_out_dir
			if [[ $create_out_dir =~ [Yy].* ]]; then
				mkdir $outdir
			else
				echo "Aborting..."
				exit 1
			fi
		else
			if ${opts['create-outdir']}; then
				mkdir $outdir
			else
				echo "ERROR: Output directory '$outdir' does not exist. Please create it or run this script with '--create-outdir' option."
				exit 1
			fi
		fi
	fi
	if [ ! -z "$(find $src -maxdepth 1 -type f -exec file -N -i -- {} + | sed -n 's!: video/[^:]*$!!p')" ]; then
		echo "NOTICE: Output directory contains other video files. Files might get overwritten."
	fi
}

set_enabled_options() {
	# Processing options

	filters=()
	enable_remove_silence=$DEFAULT_INT_RS
	enable_normalize=$DEFAULT_INT_NORM
	enable_filters=$DEFAULT_INT_AF

	normalize_filters=("dynaudnorm")
	# High/low-pass, adeclick: Remove impulsive noise (pop/click removal)
	audio_filters=("highpass=f=175" "lowpass=f=10000" "adeclick" "adeclip")

	if $interactive; then
		# Interactive
		# Remove silence
		# Will be preformed as separate pass with jumpcutter
		read -p "1st pass: Remove pauses? (y/n, default: $DEFAULT_INT_RS) " enable_remove_silence
		if [[ $enable_remove_silence =~ [Yy].* ]]; then
			enable_remove_silence="Yes"
		elif [ -z "$enable_remove_silence" ]; then
			enable_remove_silence=$DEFAULT_INT_RS
		else
			enable_remove_silence="No"
		fi

		# Audio filters (simple ffmpeg filters)
		read -p "2nd pass: Perform small audio enhancements (bandpass, remove pops) (y/n, default: $DEFAULT_INT_AF) " enable_filters
		if [[ $enable_filters =~ [Yy].* ]]; then
			filters+=(${audio_filters[@]})
			enable_filters="Yes"
		elif [ -z $enable_filters ]; then
			enable_filters=$DEFAULT_INT_AF
		else
			enable_filters='No'
		fi

		# Volume normalization (simple ffmpeg filters)
		read -p "2nd pass: Perform volume normalization? (y/n, default: $DEFAULT_INT_NORM) " enable_normalize
		if [[ $enable_normalize =~ [Yy].* ]]; then
			filters+=("${normalize_filters[@]}")
			enable_normalize="Yes"
		elif [ -z $enable_normalize ]; then
			enable_normalize=$DEFAULT_INT_NORM
		else
			enable_normalize='No'
		fi

		# Intermediate files
		echo "By default, all files are deleted in case a pass fails, including working files from previous passes. You can decide to save intermediate results if you are having troubles with passes."
		read -p "Save intermediate results? (y/n, default: $DEFAULT_SAVE_INTERM) " save_interm
		if [ -z "$save_interm" ]; then
			save_interm=$DEFAULT_SAVE_INTERM
		fi
		if [[ $save_interm =~ [Yy].* ]]; then
			opts['save-interm']=true
		else
			opts['save-interm']=false
		fi
	else
		# Static
		IFS=',' read -ra options_array <<<${opts['options']}
		for opt in "${options_array[@]}"; do
			case $opt in
			r | removesilence) enable_remove_silence='Yes' ;;
			n | normalize)
				filters+=("${normalize_filters[@]}")
				enable_normalize='Yes'
				;;
			a | audiofilters)
				filters+=(${audio_filters[@]})
				enable_filters='Yes'
				;;
			*)
				echo "ERROR: Invalid option '$opt'"
				exit 1
				;;
			esac
		done
	fi

	# Concatenate all filters with comma
	filters_string=$(
		IFS=$','
		echo "${filters[*]}"
	)
}

summary() {
	# Summary
	tot_in_duration=0
	index=1
	echo "Files to be processed:"
	for file in $files; do
		duration=$(video_duration $file)
		duration_string=$(convert_seconds $duration)
		outfile=$(filename_append $file $indir $outdir $FILENAME_SUFFIX)
		echo -e "$index\t$duration_string\t$file  =>  $outfile"
		tot_in_duration=$((tot_in_duration + duration))
		index=$((index + 1))
	done
	tot_in_duration_string=$(convert_seconds $tot_in_duration)
	echo "Total original video duration: $tot_in_duration_string"
	# echo "Estimated processing time: $(convert_seconds $((tot_in_duration/2)))"
	echo -e "Options:\n\t- Remove pauses: $enable_remove_silence\n\t- Small audio enhancements: $enable_filters\n\t- Normalize volume: $enable_normalize"
	echo "Warning: This process could take up to ~60% of the original video duration to complete"

	if $interactive; then
		read -p "Proceed? (y/n) " proceed
		if [[ ! $proceed =~ [Yy].* ]]; then
			echo "Aborting..."
			exit 1
		fi
	fi
}

process() {
	# Process files

	# Create temporary directory
	mkdir -p $TMP_DIR

	tot_out_duration=0
	for file in $files; do
		outfile=$(filename_append $file $indir $outdir $FILENAME_SUFFIX)
		echo "Processing '$file' => '$outfile'"
		curfile=$file
		# Pass 1: Remove silence
		if [ $enable_remove_silence = 'Yes' ]; then
			echo "1st pass: Remove pauses"
			tmpname=$(tmp_filename $file)
			cmd="jumpcutter --input \"$curfile\" --output \"$tmpname\""
			if ${opts['dry-run']}; then
				echo $cmd
			else
				eval $cmd
			fi
			curfile=$tmpname
		else
			echo "1st pass: Nothing to do, skipping..."
		fi

		# Copy intermediate files
		if ! ${opts['dry-run']} && ${opts['save-interm']}; then
			echo "Copying intermediate files..."
			interm_fn=$(filename_append $outfile $outdir $outdir 'interm')
			cp $curfile $interm_fn
		fi

		# Pass 2: Filters
		if [ $enable_normalize = 'Yes' ] || [ $enable_filters = 'Yes' ]; then
			echo "2nd pass: Audio filters"
			# If any video filters are used, -vcodec copy must be removed
			tmpname=$(tmp_filename $file)
			cmd="$FFMPEG_FRONTEND -i \"$curfile\" -af \"$filters_string\" -vcodec copy -y \"$tmpname\""
			if ${opts['dry-run']}; then
				echo $cmd
			else
				eval $cmd
			fi
			curfile=$tmpname
		else
			echo "2nd pass: Nothing to do, skipping..."
		fi

		# Copy file to final file
		if ! ${opts['dry-run']}; then
			cp $curfile $outfile
			# Stats
			duration=$(video_duration $outfile)
			duration_string=$(convert_seconds $duration)
			tot_out_duration=$(($tot_out_duration + $duration))
		fi

		# Remove intermediate file
		if ! ${opts['dry-run']} && ${opts['save-interm']} && [ -f $interm_fn ]; then
			echo "Removing intermediate files..."
			rm $interm_fn
		fi

		echo "SUCCESS: File processed (result: '$outfile', $duration_string)"
	done

	tot_out_duration_string=$(convert_seconds $tot_out_duration)
	percentage_less=$(printf "%.2f" $(echo "($tot_in_duration - $tot_out_duration) / $tot_in_duration * 100" | bc -l))
	echo "Processing complete. Final duration: $tot_out_duration_string ($percentage_less% shorter)"
}

run() {

	# Need to check requirements before starting (figlet is used in title screen)
	check_requirements

	if $interactive; then
		echo "Welcome to"
		figlet -f slant "$APP_NAME"
		echo "When prompted, simply type <enter> to accept default settings."
	fi

	set_input_files

	set_output_dir

	set_enabled_options

	summary

	process
}

###########################
# MAIN PROGRAM ENTRYPOINT #
###########################

# Values needed:
# - source file/dir => files list
# - output dir
# - options enabled:
#		- remove silence
#		- normalize volume
# 		- audio enhancements

# Command parsing

# Positional args
posargs=()

# Options
declare -A opts=(
	['install-deps']=false
	['no-recurse']=false
	['create-outdir']=false
	['options']=$DEFAULT_CLI_FILTERS
	['dry-run']=false
	['save-interm']=false
)

interactive=false

program='run'

while [ "$#" -gt 0 ]; do
	case "$1" in
	-i | --interactive)
		interactive=true
		shift 1
		;;
	-d | --install-deps)
		opts['install-deps']=true
		shift 1
		;;
	-n | --norecurse)
		opts['no-recurse']=true
		shift 1
		;;
	-c | --create-outdir)
		opts['create-outdir']=true
		shift 1
		;;
	-o | --options)
		opts['options']=$2
		shift 2
		;;
	-h | --help)
		program='usage'
		shift 1
		;;
	-v | --version)
		program='version'
		shift 1
		;;
	-r | --dry-run)
		opts['dry-run']=true
		shift 1
		;;
	-s | --save-interm)
		opts['save-interm']=true
		shift 1
		;;
	-*)
		echo "Unkown option '$1'" >&2
		exit 1
		;;
	*)
		posargs+=("$1")
		shift 1
		;;
	esac
done

if ! $interactive; then
	echo "Running in CLI mode"
else
	echo "Running in interactive mode"
fi

if ! $interactive && [ -z ${posargs[0]} ]; then
	echo "ERROR: Either specify a source file as first positional argument or run this program interactively with $prog_name -i" >&2
	exit 1
fi

$program

TIME_END=$(date +%s)
TIME_DIFF=$(($TIME_END - $TIME_START))
time_taken=$(convert_seconds $TIME_DIFF)

echo "Completed in $time_taken"
