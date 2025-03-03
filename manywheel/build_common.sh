#!/usr/bin/env bash
# meant to be called only from the neighboring build.sh and build_cpu.sh scripts

set -ex
SOURCE_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"


# Require only one python installation
if [[ -z "$DESIRED_PYTHON" ]]; then
    echo "Need to set DESIRED_PYTHON env variable"
    exit 1
fi
if [[ -n "$BUILD_PYTHONLESS" && -z "$LIBTORCH_VARIANT" ]]; then
    echo "BUILD_PYTHONLESS is set, so need LIBTORCH_VARIANT to also be set"
    echo "LIBTORCH_VARIANT should be one of shared-with-deps shared-without-deps static-with-deps static-without-deps"
    exit 1
fi

# Function to retry functions that sometimes timeout or have flaky failures
retry () {
    $*  || (sleep 1 && $*) || (sleep 2 && $*) || (sleep 4 && $*) || (sleep 8 && $*)
}

# TODO move this into the Docker images
OS_NAME=$(awk -F= '/^NAME/{print $2}' /etc/os-release)
if [[ "$OS_NAME" == *"CentOS Linux"* ]]; then
    retry yum install -q -y zip openssl
elif [[ "$OS_NAME" == *"Ubuntu"* ]]; then
    # TODO: Remove this once nvidia package repos are back online
    # Comment out nvidia repositories to prevent them from getting apt-get updated, see https://github.com/pytorch/pytorch/issues/74968
    # shellcheck disable=SC2046
    sed -i 's/.*nvidia.*/# &/' $(find /etc/apt/ -type f -name "*.list")

    retry apt-get update
    retry apt-get -y install zip openssl
fi

# We use the package name to test the package by passing this to 'pip install'
# This is the env variable that setup.py uses to name the package. Note that
# pip 'normalizes' the name first by changing all - to _
if [[ -z "$TORCH_PACKAGE_NAME" ]]; then
    TORCH_PACKAGE_NAME='torch'
fi
TORCH_PACKAGE_NAME="$(echo $TORCH_PACKAGE_NAME | tr '-' '_')"
echo "Expecting the built wheels to all be called '$TORCH_PACKAGE_NAME'"

# Version: setup.py uses $PYTORCH_BUILD_VERSION.post$PYTORCH_BUILD_NUMBER if
# PYTORCH_BUILD_NUMBER > 1
build_version="$PYTORCH_BUILD_VERSION"
build_number="$PYTORCH_BUILD_NUMBER"
if [[ -n "$OVERRIDE_PACKAGE_VERSION" ]]; then
    # This will be the *exact* version, since build_number<1
    build_version="$OVERRIDE_PACKAGE_VERSION"
    build_number=0
fi
if [[ -z "$build_version" ]]; then
    build_version=1.0.0
fi
if [[ -z "$build_number" ]]; then
    build_number=1
fi
export PYTORCH_BUILD_VERSION=$build_version
export PYTORCH_BUILD_NUMBER=$build_number

export CMAKE_LIBRARY_PATH="/opt/intel/lib:/lib:$CMAKE_LIBRARY_PATH"
export CMAKE_INCLUDE_PATH="/opt/intel/include:$CMAKE_INCLUDE_PATH"

if [[ -e /opt/openssl ]]; then
    export OPENSSL_ROOT_DIR=/opt/openssl
    export CMAKE_INCLUDE_PATH="/opt/openssl/include":$CMAKE_INCLUDE_PATH
fi

# If given a python version like 3.6m or 2.7mu, convert this to the format we
# expect. The binary CI jobs pass in python versions like this; they also only
# ever pass one python version, so we assume that DESIRED_PYTHON is not a list
# in this case
if [[ -n "$DESIRED_PYTHON" && "$DESIRED_PYTHON" != cp* ]]; then
    python_nodot="$(echo $DESIRED_PYTHON | tr -d m.u)"
    case ${DESIRED_PYTHON} in
      3.[6-7]*)
        DESIRED_PYTHON="cp${python_nodot}-cp${python_nodot}m"
        ;;
      # Should catch 3.8+
      3.*)
        DESIRED_PYTHON="cp${python_nodot}-cp${python_nodot}"
        ;;
    esac
fi

if [[ ${python_nodot} -ge 310 ]]; then
    py_majmin="${DESIRED_PYTHON:2:1}.${DESIRED_PYTHON:3:2}"
else
    py_majmin="${DESIRED_PYTHON:2:1}.${DESIRED_PYTHON:3:1}"
fi


pydir="/opt/python/$DESIRED_PYTHON"
export PATH="$pydir/bin:$PATH"
echo "Will build for Python version: ${DESIRED_PYTHON} with ${python_installation}"

mkdir -p /tmp/$WHEELHOUSE_DIR

export PATCHELF_BIN=/usr/local/bin/patchelf
patchelf_version=$($PATCHELF_BIN --version)
echo "patchelf version: " $patchelf_version
if [[ "$patchelf_version" == "patchelf 0.9" ]]; then
    echo "Your patchelf version is too old. Please use version >= 0.10."
    exit 1
fi

########################################################
# Compile wheels as well as libtorch
#######################################################
if [[ -z "$PYTORCH_ROOT" ]]; then
    echo "Need to set PYTORCH_ROOT env variable"
    exit 1
fi
pushd "$PYTORCH_ROOT"
python setup.py clean
retry pip install -qr requirements.txt
case ${DESIRED_PYTHON} in
  cp36-cp36m)
    retry pip install -q numpy==1.11
    ;;
  cp3[7-8]*)
    retry pip install -q numpy==1.15
    ;;
  cp310*)
    retry pip install -q numpy==1.21.2
    ;;
  # Should catch 3.9+
  *)
    retry pip install -q numpy==1.19.4
    ;;
esac

if [[ "$DESIRED_DEVTOOLSET" == *"cxx11-abi"* ]]; then
    export _GLIBCXX_USE_CXX11_ABI=1
    export USE_LLVM="/opt/llvm"
    export LLVM_DIR="$USE_LLVM/lib/cmake/llvm"
else
    export _GLIBCXX_USE_CXX11_ABI=0
    export USE_LLVM="/opt/llvm_no_cxx11_abi"
    export LLVM_DIR="$USE_LLVM/lib/cmake/llvm"
fi

if [[ "$DESIRED_CUDA" == *"rocm"* ]]; then
    echo "Calling build_amd.py at $(date)"
    python tools/amd_build/build_amd.py
fi

# This value comes from binary_linux_build.sh (and should only be set to true
# for master / release branches)
BUILD_DEBUG_INFO=${BUILD_DEBUG_INFO:=0}

if [[ $BUILD_DEBUG_INFO == "1" ]]; then
    echo "Building wheel and debug info"
else
    echo "BUILD_DEBUG_INFO was not set, skipping debug info"
fi

echo "Calling setup.py bdist at $(date)"
time CMAKE_ARGS=${CMAKE_ARGS[@]} \
     EXTRA_CAFFE2_CMAKE_FLAGS=${EXTRA_CAFFE2_CMAKE_FLAGS[@]} \
     BUILD_LIBTORCH_CPU_WITH_DEBUG=$BUILD_DEBUG_INFO \
     python setup.py bdist_wheel -d /tmp/$WHEELHOUSE_DIR
echo "Finished setup.py bdist at $(date)"

# Build libtorch packages
if [[ -n "$BUILD_PYTHONLESS" ]]; then
    # Now build pythonless libtorch
    # Note - just use whichever python we happen to be on
    python setup.py clean

    if [[ $LIBTORCH_VARIANT = *"static"* ]]; then
        STATIC_CMAKE_FLAG="-DTORCH_STATIC=1"
    fi

    mkdir -p build
    pushd build
    echo "Calling tools/build_libtorch.py at $(date)"
    time CMAKE_ARGS=${CMAKE_ARGS[@]} \
         EXTRA_CAFFE2_CMAKE_FLAGS="${EXTRA_CAFFE2_CMAKE_FLAGS[@]} $STATIC_CMAKE_FLAG" \
         python ../tools/build_libtorch.py
    echo "Finished tools/build_libtorch.py at $(date)"
    popd

    mkdir -p libtorch/{lib,bin,include,share}
    cp -r build/build/lib libtorch/

    # for now, the headers for the libtorch package will just be copied in
    # from one of the wheels (this is from when this script built multiple
    # wheels at once)
    ANY_WHEEL=$(ls /tmp/$WHEELHOUSE_DIR/torch*.whl | head -n1)
    unzip -d any_wheel $ANY_WHEEL
    if [[ -d any_wheel/torch/include ]]; then
        cp -r any_wheel/torch/include libtorch/
    else
        cp -r any_wheel/torch/lib/include libtorch/
    fi
    cp -r any_wheel/torch/share/cmake libtorch/share/
    rm -rf any_wheel

    echo $PYTORCH_BUILD_VERSION > libtorch/build-version
    echo "$(pushd $PYTORCH_ROOT && git rev-parse HEAD)" > libtorch/build-hash

    mkdir -p /tmp/$LIBTORCH_HOUSE_DIR

    if [[ "$DESIRED_DEVTOOLSET" == *"cxx11-abi"* ]]; then
        LIBTORCH_ABI="cxx11-abi-"
    else
        LIBTORCH_ABI=
    fi

    zip -rq /tmp/$LIBTORCH_HOUSE_DIR/libtorch-$LIBTORCH_ABI$LIBTORCH_VARIANT-$PYTORCH_BUILD_VERSION.zip libtorch
    cp /tmp/$LIBTORCH_HOUSE_DIR/libtorch-$LIBTORCH_ABI$LIBTORCH_VARIANT-$PYTORCH_BUILD_VERSION.zip \
       /tmp/$LIBTORCH_HOUSE_DIR/libtorch-$LIBTORCH_ABI$LIBTORCH_VARIANT-latest.zip
fi

popd

#######################################################################
# ADD DEPENDENCIES INTO THE WHEEL
#
# auditwheel repair doesn't work correctly and is buggy
# so manually do the work of copying dependency libs and patchelfing
# and fixing RECORDS entries correctly
######################################################################

fname_with_sha256() {
    HASH=$(sha256sum $1 | cut -c1-8)
    DIRNAME=$(dirname $1)
    BASENAME=$(basename $1)
    # Do not rename nvrtc-builtins.so as they are dynamically loaded
    # by libnvrtc.so
    # Similarly don't mangle libcudnn and libcublas library names
    if [[ $BASENAME == "libnvrtc-builtins.s"* || $BASENAME == "libcudnn"* || $BASENAME == "libcublas"*  ]]; then
        echo $1
    else
        INITNAME=$(echo $BASENAME | cut -f1 -d".")
        ENDNAME=$(echo $BASENAME | cut -f 2- -d".")
        echo "$DIRNAME/$INITNAME-$HASH.$ENDNAME"
    fi
}

fname_without_so_number() {
    LINKNAME=$(echo $1 | sed -e 's/\.so.*/.so/g')
    echo "$LINKNAME"
}

make_wheel_record() {
    FPATH=$1
    if echo $FPATH | grep RECORD >/dev/null 2>&1; then
        # if the RECORD file, then
        echo "$FPATH,,"
    else
        HASH=$(openssl dgst -sha256 -binary $FPATH | openssl base64 | sed -e 's/+/-/g' | sed -e 's/\//_/g' | sed -e 's/=//g')
        FSIZE=$(ls -nl $FPATH | awk '{print $5}')
        echo "$FPATH,sha256=$HASH,$FSIZE"
    fi
}

replace_needed_sofiles() {
    find $1 -name '*.so*' | while read sofile; do
        origname=$2
        patchedname=$3
        if [[ "$origname" != "$patchedname" ]]; then
            set +e
            $PATCHELF_BIN --print-needed $sofile | grep $origname 2>&1 >/dev/null
            ERRCODE=$?
            set -e
            if [ "$ERRCODE" -eq "0" ]; then
                echo "patching $sofile entry $origname to $patchedname"
                $PATCHELF_BIN --replace-needed $origname $patchedname $sofile
            fi
        fi
    done
}

echo 'Built this wheel:'
ls /tmp/$WHEELHOUSE_DIR
mkdir -p "/$WHEELHOUSE_DIR"
mv /tmp/$WHEELHOUSE_DIR/torch*linux*.whl /$WHEELHOUSE_DIR/
if [[ -n "$BUILD_PYTHONLESS" ]]; then
    mkdir -p /$LIBTORCH_HOUSE_DIR
    mv /tmp/$LIBTORCH_HOUSE_DIR/*.zip /$LIBTORCH_HOUSE_DIR
    rm -rf /tmp/$LIBTORCH_HOUSE_DIR
fi
rm -rf /tmp/$WHEELHOUSE_DIR
rm -rf /tmp_dir
mkdir /tmp_dir
pushd /tmp_dir

for pkg in /$WHEELHOUSE_DIR/torch*linux*.whl /$LIBTORCH_HOUSE_DIR/libtorch*.zip; do

    # if the glob didn't match anything
    if [[ ! -e $pkg ]]; then
        continue
    fi

    rm -rf tmp
    mkdir -p tmp
    cd tmp
    cp $pkg .

    unzip -q $(basename $pkg)
    rm -f $(basename $pkg)

    if [[ -d torch ]]; then
        PREFIX=torch
    else
        PREFIX=libtorch
    fi

    if [[ $pkg != *"without-deps"* ]]; then
        # copy over needed dependent .so files over and tag them with their hash
        patched=()
        for filepath in "${DEPS_LIST[@]}"; do
            filename=$(basename $filepath)
            destpath=$PREFIX/lib/$filename
            if [[ "$filepath" != "$destpath" ]]; then
                cp $filepath $destpath
            fi

            # ROCm workaround for roctracer dlopens
            if [[ "$DESIRED_CUDA" == *"rocm"* ]]; then
                patchedpath=$(fname_without_so_number $destpath)
            else
                patchedpath=$(fname_with_sha256 $destpath)
            fi
            patchedname=$(basename $patchedpath)
            if [[ "$destpath" != "$patchedpath" ]]; then
                mv $destpath $patchedpath
            fi
            patched+=("$patchedname")
            echo "Copied $filepath to $patchedpath"
        done

        echo "patching to fix the so names to the hashed names"
        for ((i=0;i<${#DEPS_LIST[@]};++i)); do
            replace_needed_sofiles $PREFIX ${DEPS_SONAME[i]} ${patched[i]}
            # do the same for caffe2, if it exists
            if [[ -d caffe2 ]]; then
                replace_needed_sofiles caffe2 ${DEPS_SONAME[i]} ${patched[i]}
            fi
        done

        # copy over needed auxiliary files
        for ((i=0;i<${#DEPS_AUX_SRCLIST[@]};++i)); do
            srcpath=${DEPS_AUX_SRCLIST[i]}
            dstpath=$PREFIX/${DEPS_AUX_DSTLIST[i]}
            mkdir -p $(dirname $dstpath)
            cp $srcpath $dstpath
        done
    fi

    # set RPATH of _C.so and similar to $ORIGIN, $ORIGIN/lib
    find $PREFIX -maxdepth 1 -type f -name "*.so*" | while read sofile; do
        echo "Setting rpath of $sofile to " '$ORIGIN:$ORIGIN/lib'
        $PATCHELF_BIN --set-rpath '$ORIGIN:$ORIGIN/lib' $sofile
        $PATCHELF_BIN --print-rpath $sofile
    done

    # set RPATH of lib/ files to $ORIGIN
    find $PREFIX/lib -maxdepth 1 -type f -name "*.so*" | while read sofile; do
        echo "Setting rpath of $sofile to " '$ORIGIN'
        $PATCHELF_BIN --set-rpath '$ORIGIN' $sofile
        $PATCHELF_BIN --print-rpath $sofile
    done

    # regenerate the RECORD file with new hashes
    record_file=$(echo $(basename $pkg) | sed -e 's/-cp.*$/.dist-info\/RECORD/g')
    if [[ -e $record_file ]]; then
        echo "Generating new record file $record_file"
        rm -f $record_file
        # generate records for folders in wheel
        find * -type f | while read fname; do
            echo $(make_wheel_record $fname) >>$record_file
        done
    fi

    if [[ $BUILD_DEBUG_INFO == "1" ]]; then
        pushd "$PREFIX/lib"

        # Duplicate library into debug lib
        cp libtorch_cpu.so libtorch_cpu.so.dbg

        # Keep debug symbols on debug lib
        strip --only-keep-debug libtorch_cpu.so.dbg

        # Remove debug info from release lib
        strip --strip-debug libtorch_cpu.so

        objcopy libtorch_cpu.so --add-gnu-debuglink=libtorch_cpu.so.dbg

        # Zip up debug info
        mkdir -p /tmp/debug
        mv libtorch_cpu.so.dbg /tmp/debug/libtorch_cpu.so.dbg
        CRC32=$(objcopy --dump-section .gnu_debuglink=>(tail -c4 | od -t x4 -An | xargs echo) libtorch_cpu.so)

        pushd /tmp
        PKG_NAME=$(basename "$pkg" | sed 's/\.whl$//g')
        zip /tmp/debug-whl-libtorch-"$PKG_NAME"-"$CRC32".zip /tmp/debug/libtorch_cpu.so.dbg
        cp /tmp/debug-whl-libtorch-"$PKG_NAME"-"$CRC32".zip "$PYTORCH_FINAL_PACKAGE_DIR"
        popd

        popd
    fi

    # zip up the wheel back
    zip -rq $(basename $pkg) $PREIX*

    # replace original wheel
    rm -f $pkg
    mv $(basename $pkg) $pkg
    cd ..
    rm -rf tmp
done

# Copy wheels to host machine for persistence before testing
if [[ -n "$PYTORCH_FINAL_PACKAGE_DIR" ]]; then
    mkdir -p "$PYTORCH_FINAL_PACKAGE_DIR" || true
    if [[ -n "$BUILD_PYTHONLESS" ]]; then
        cp /$LIBTORCH_HOUSE_DIR/libtorch*.zip "$PYTORCH_FINAL_PACKAGE_DIR"
    else
        cp /$WHEELHOUSE_DIR/torch*.whl "$PYTORCH_FINAL_PACKAGE_DIR"
    fi
fi

# remove stuff before testing
rm -rf /opt/rh
if ls /usr/local/cuda* >/dev/null 2>&1; then
    rm -rf /usr/local/cuda*
fi


# Test that all the wheels work
if [[ -z "$BUILD_PYTHONLESS" ]]; then
  export OMP_NUM_THREADS=4 # on NUMA machines this takes too long
  pushd $PYTORCH_ROOT/test

  # Install the wheel for this Python version
  pip uninstall -y "$TORCH_PACKAGE_NAME"
  pip install "$TORCH_PACKAGE_NAME" --no-index -f /$WHEELHOUSE_DIR --no-dependencies -v

  # Print info on the libraries installed in this wheel
  # Rather than adjust find command to skip non-library files with an embedded *.so* in their name,
  # since this is only for reporting purposes, we add the || true to the ldd command.
  installed_libraries=($(find "$pydir/lib/python${py_majmin}/site-packages/torch/" -name '*.so*'))
  echo "The wheel installed all of the libraries: ${installed_libraries[@]}"
  for installed_lib in "${installed_libraries[@]}"; do
      ldd "$installed_lib" || true
  done

  # Run the tests
  echo "$(date) :: Running tests"
  pushd "$PYTORCH_ROOT"
  LD_LIBRARY_PATH=/usr/local/nvidia/lib64 \
          "${SOURCE_DIR}/../run_tests.sh" manywheel "${py_majmin}" "$DESIRED_CUDA"
  popd
  echo "$(date) :: Finished tests"
fi
