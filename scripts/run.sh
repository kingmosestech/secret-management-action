#!/bin/bash

install_on_windows_wsl() {
    sudo apt-get update
    sudo apt-get install -y python3-pip
    curl -s https://raw.githubusercontent.com/terraform-linters/tflint/master/install_linux.sh | bash
    pip3 install pre-commit
    pre-commit install
}