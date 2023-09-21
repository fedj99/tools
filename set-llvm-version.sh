#!/bin/bash

set -e

APP_NAME='set-llvm-version'
APP_VERSION='1.0.0'

usage() {
	echo "$APP_NAME - version $APP_VERSION"
	echo ""
	echo "SYNOPSIS"
	echo "	Sets the default version of any program included in the llvm package."
	echo ""
	echo "USAGE"
	echo "	./set-llvm-version.sh [...options]"
	echo ""
	echo "OPTIONS"
	echo "	-n, --name <prog> <ver>  Sets the default version for the specified program"
	echo "	-a, --all <ver>          Sets the default version on ALL LLVM-related programs found in"
	echo "	                         LLVM's installation directory"
	echo "	-i, --install-dir <dri>  Optionally specify a non-standard installation directory"
	echo "	-h, --help               Display this help message"
	echo ""
	echo "	<prog>                   Program name to set version of (e.g. 'llc')"
	echo "	<ver>                    Desired version (e.g. '9')"
	echo "	<dir>                    Non-standard installation directory (e.g. '/usr/local/bin')"
	echo ""
	echo "AUTHOR"
	echo "	Federico Mantovani <fmantova@student.ethz.ch>"
	echo ""
	echo "LICENSE"
	echo "	MIT License, Copyright (c) 2021 Federico Mantovani"
}

check_install_dir() {
	if [ -z $installdir ]; then
		echo "Unable to locate installation directory - Please provide one with --install-dir (see --help for more info)"
		exit 1
	fi
}

check_ver() {
	if ! [[ $ver =~ [0-9]+ ]]; then
		echo "Version must be an integer"
		exit 1
	fi
}

config() {
	check_ver
	check_install_dir

	sudo update-alternatives --install "$installdir/$1" "$1" "$installdir/$1-$ver" $ver
	sudo update-alternatives --config "$1"
}

all() {
	echo "Setting llvm version to $ver..."
	progs=$(ls $installdir | grep "\(llvm\|llc\|clang\).*-$ver")
	for prog in $progs; do
		config "${prog%-$ver}"
	done
}

# Argument parsing
program="main"
args=()

custom_install_dir="" # Only set if using --install-dir
progname=""           # Only set if using --name
ver=""                # Set in all cases

while [ "$#" -gt 0 ]; do
	case "$1" in
	-h | --help)
		program="usage"
		shift 1
		;;
	-n | --name)
		progname=$2
		ver=$3
		program="config $2"
		shift 3
		;;
	-a | --all)
		program="all"
		ver=$2
		shift 2
		;;
	-i | --install-dir)
		custom_install_dir=$2
		shift 2
		;;
	*)
		args+=("$1")
		shift 1
		;;
	esac
done

# Try to automatically set installation directory
installdir=$(dirname $(which llc) || echo '')

eval $program
