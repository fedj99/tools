#!/bin/bash
set -e

APP_NAME='CHOPPER'

convert_seconds () {
	local secs=${1%.*}
	printf '%02dh %02dm %02ds\n' $((secs/3600)) $((secs%3600/60)) $((secs%60))
}

video_duration () { 
	local x=$(ffprobe -i $1 -show_entries format=duration -v quiet -of csv="p=0")
	echo "${x%.*}"
}

echo "Welcome to $APP_NAME!"

# Requirements
echo "Checking requirements..."
if ! command -v ffmpeg &> /dev/null
then
	echo "Missing dependency: ffmpeg - Please install before proceeding"
	read -p "Install now? (y/n) " install_deps
	case $install_deps in
		[Yy]* ) sudo apt-get install ffmpeg;;
		* ) echo "This program can't run without ffmpeg. Please install and try again."; exit;;
	esac
fi
echo "All requirements met."

# Input files
read -p "Source directory: " src
files=$(find $src -type f -exec file -N -i -- {} + | sed -n 's!: video/[^:]*$!!p')
if [ ! -d $src ]
then
	echo "Not a directory, aborting..."
	exit
fi

# Output directory
read -p "Output directory: " outdir
if [ ! -d $outdir ]
then
	read -p "Output directory does not exist. Create now? (y/n) " create_out_dir
	case $create_out_dir in
		[Yy]* ) mkdir $outdir ;;
		* ) echo "Aborting..." ;;
	esac
fi

# Processing options
filters=()

read -p "Remove pauses? (y/n) " enable_remove_silence
case $enable_remove_silence in
	[Yy]* ) filters+=("silenceremove=1:0:-50dB") ;;
	* ) ;;
esac

read -p "Perform volume normalization? (y/n) " enable_normalize
case $enable_normalize in
	[Yy]* ) filters+=("dynaudnorm");;
	* ) ;;
esac

filters_string=$( IFS=$','; echo "${filters[*]}" )

# Summary
tot_in_duration=0
index=1
echo "Files to be processed:"
for file in $files; do
	duration=$( video_duration $file )
	duration_string=$( convert_seconds $duration )
	echo -e "$index\t$duration_string\t$file"
	tot_in_duration=$((tot_in_duration+duration))
	index=$((index+1))
done
tot_in_duration_string=$( convert_seconds $tot_in_duration )
echo "Total original video duration: $tot_in_duration_string"
echo "Estimated processing time: $(convert_seconds $((tot_in_duration/2)))"
echo "Options: Remove pauses: $enable_remove_silence, normalize: $enable_normalize"

read -p "Proceed? (y/n) " proceed
case $proceed in
	[Yy]* ) ;;
	* ) echo "Aborting..."; exit;;
esac

# Process
tot_out_duration=0
for file in $files; do
	echo "Processing '$file'..."
	base="${file#$src'/'}"
	name="${base%%.*}"
	ext="${base##*.}"
	outfile="$outdir/${name}_chopped.$ext"
	ffmpeg -i $file -af $filters_string $outfile -y
	duration=$( video_duration $outfile )
	duration_string=$( convert_seconds $duration )
	tot_out_duration=$(($tot_out_duration + $duration))
	echo "Done (result: '$outfile', $duration_string)"
done

tot_out_duration_string=$( convert_seconds $tot_out_duration )
percentage_less=$((($tot_in_duration - $tot_out_duration) / $tot_in_duration))
echo "Processing complete. Final duration: $tot_out_duration_string ($percentage_less% shorter)"
