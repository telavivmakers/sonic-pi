#!/bin/bash
set -e # Quit script on error

while getopts ":n" opt; do
  case $opt in
    n)
      no_imgui=true
      echo "Running prebuild script without support for IMGUI-based GUI"
      ;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      exit 1
      ;;
  esac
done

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
WORKING_DIR="$(pwd)"

cd "${SCRIPT_DIR}"

# Build vcpkg
if [ ! -d "vcpkg" ]; then
    echo "Cloning vcpkg"
    git clone --depth 1 --branch 2022.02.02  https://github.com/microsoft/vcpkg.git vcpkg
fi

if [ ! -f "vcpkg/vcpkg" ]; then
    echo "Building vcpkg"
    cd vcpkg
    ./bootstrap-vcpkg.sh -disableMetrics
    cd "${SCRIPT_DIR}"
fi

cd vcpkg
triplet=(x64-osx)

if [ "$no_imgui" == true ]
then
    ./vcpkg install kissfft crossguid platform-folders reproc catch2 --triplet ${triplet[0]} --recurse
else
    ./vcpkg install kissfft fmt sdl2 gl3w reproc gsl-lite concurrentqueue platform-folders catch2 --triplet ${triplet[0]} --recurse
fi


# Restore working directory as it was prior to this script running...
cd "${WORKING_DIR}"