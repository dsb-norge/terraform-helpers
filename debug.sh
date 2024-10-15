#!/usr/bin/env bash

source ./dsb-tf-proj-helpers.sh ;
pushd /home/peder/code/github/dsb-norge/azure-ad >/dev/null ;
tf-select-env ;
tf-check-dir ;
popd >/dev/null ;
