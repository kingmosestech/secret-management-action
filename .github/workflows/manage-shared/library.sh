#!/bin/bash

# Utility function to check if required environment variables are set
check_inputs() {
if [[ -z "${!1}" ]]; then
   echo "[ERROR] Input variable ${1} is not set."
   exit 1
fi
}