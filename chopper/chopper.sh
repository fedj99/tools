#!/bin/bash
set -e

APP_NAME='CHOPPER'
FILENAME_SUFFIX='chopped'
TMP_DIR='tmp'

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
	fi
}

filename_append() {
	# $1: Original filename
	# $2: Base source directory
	# $3: Base output directory
	# $2: String to append
	local base="${1#$2'/'}"
	local name="${base%%.*}"
	local ext="${base##*.}"
	echo "$3/${name}_chopped.$ext"
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
	if [ -d $TMP_DIR ]; then
		rm -r $TMP_DIR
	fi
}

trap cleanup EXIT

echo "Welcome to $APP_NAME!"
echo "When prompted, simply type <enter> to accept default settings."

# Requirements
echo "Checking requirements..."

check_requirement "ffmpeg" \
	"sudo apt update" \
	"sudo apt install ffmpeg"

check_requirement "python3" \
	"sudo apt update" \
	"sudo apt install software-properties-common" \
	"sudo add-apt-repository ppa:deadsnakes/ppa" \
	"sudo apt update" \
	"sudo apt install python3"

check_requirement "pip3" \
	"python -m ensurepip --upgrade"

check_requirement "jumpcutter" \
	"pip3 install jumpcutter"

check_requirement "ffpb" \
	"pip3 install ffpb"

echo "All requirements met."

# Input files
read -e -p "Source file/directory: " src
src=${src%/} # Trim trailing slash
if [ -f $src ]; then
	files=$src # Just a single file
	indir=$(dirname $src)
elif [ -d $src ]; then
	read -p "Recurse subdirectories? (y/n) " recurse_subdirs
	if [[ $recurse_subdirs =~ [Yy].* ]]; then
		files=$(find $src -type f -exec file -N -i -- {} + | sed -n 's!: video/[^:]*$!!p')
	else
		files=$(find $src -maxdepth 1 -type f -exec file -N -i -- {} + | sed -n 's!: video/[^:]*$!!p')
	fi
	indir=$src
else
	echo "Not a directory, aborting..."
	exit
fi

# Output directory
read -e -p "Output directory: " outdir
outdir=${outdir%/} # Trim trailing slash
if [ ! -d $outdir ]; then
	read -p "Output directory does not exist. Create now? (y/n) " create_out_dir
	if [[ $create_out_dir =~ [Yy].* ]]; then
		mkdir $outdir
	else
		echo "Aborting..."
	fi
fi
if [ ! -z $(find $src -maxdepth 1 -type f -exec file -N -i -- {} + | sed -n 's!: video/[^:]*$!!p') ]; then
	echo "Output directory contains other video files. Files might get overwritten."
fi

# Processing options
filters=()

# Remove silence
# Will be preformed as separate pass with jumpcutter
default_remove_silence="Yes"
read -p "1st pass: Remove pauses? (y/n, default: $default_remove_silence) " enable_remove_silence
if [[ $enable_remove_silence =~ [Yy].* ]]; then
	enable_remove_silence="Yes"
elif [ -z "$enable_remove_silence" ]; then
	enable_remove_silence=$default_remove_silence
else
	enable_remove_silence="No"
fi

# Volume normalization
# Simple ffmpeg filter
default_normalize="No"
read -p "2nd pass: Perform volume normalization? (y/n, default: $default_normalize) " enable_normalize
if [[ $enable_normalize =~ [Yy].* ]]; then
	filters+=("dynaudnorm")
	enable_normalize="Yes"
elif [ -z $enable_normalize ]; then
	enable_normalize=$default_normalize
fi

default_filters="No"
read -p "2nd pass: Perform small audio enhancements (bandpass, remove pops) (y/n, default: $default_filters) " enable_filters
if [[ $enable_filters =~ [Yy].* ]]; then
	# High/low-pass, adeclick: Remove impulsive noise (pop/click removal)
	filters+=("highpass=f=175" "lowpass=f=10000" "adeclick" "adeclip")
	enable_filters="Yes"
elif [ -z $enable_filters ]; then
	enable_filters=$default_filters
fi

# Concatenate all filters with comma
OLDIFS=$IFS
filters_string=$(
	IFS=$','
	echo "${filters[*]}"
)
IFS=$OLDIFS

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
echo -e "Options:\n\t- Remove pauses: $enable_remove_silence\n\t- Normalize volume: $enable_normalize\n\t- Small audio enhancements: $enable_filters"
echo "Warning: This process can take about 30-60% of the original video duration to complete"

read -p "Proceed? (y/n) " proceed
if [[ ! $proceed =~ [Yy].* ]]; then
	echo "Aborting..."
	exit
fi

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
		jumpcutter \
			--input $curfile \
			--output $tmpname
		curfile=$tmpname
	else
		echo "1st pass: Nothing to do, skipping..."
	fi
	# Pass 2: Filters
	if [ $enable_normalize = 'Yes' ] || [ $enable_filters = 'Yes' ]; then
		echo "2nd pass: Audio filters"
		# If any video filters are used, -vcodec copy must be removed
		tmpname=$(tmp_filename $file)
		ffpb -i $curfile -af $filters_string -vcodec copy -y $tmpname
		curfile=$tmpname
	else
		echo "2nd pass: Nothing to do, skipping..."
	fi
	# Copy file to final file
	cp $curfile $outfile
	# Stats
	duration=$(video_duration $outfile)
	duration_string=$(convert_seconds $duration)
	tot_out_duration=$(($tot_out_duration + $duration))
	echo "File processed (result: '$outfile', $duration_string)"
done

tot_out_duration_string=$(convert_seconds $tot_out_duration)
percentage_less=$(printf "%.2f" $(echo "($tot_in_duration - $tot_out_duration) / $tot_in_duration * 100" | bc -l))
echo "Processing complete. Final duration: $tot_out_duration_string ($percentage_less% shorter)"
