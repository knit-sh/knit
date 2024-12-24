#!/bin/bash

################################################################################
# MIT License
#
# Copyright (c) [year] [fullname]
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
################################################################################

KNIT_VERSION=0.0.1

source "src/log.sh"
source "src/set.sh"
source "src/args.sh"
source "src/register.sh"
source "src/usage.sh"

# ------------------------------------------------------------------------------
# This is the main function that invokes the Knit framework. Users should call
# it as follows at the end of their bash script to forward all arguments to it.
#
# ```
# knit $@
# ```
# ------------------------------------------------------------------------------
knit() {
    if [ "$#" -eq 0 ]; then
        _knit_print_usage
    else
        if _knit_find_flag "-h,--help" $@; then
            _knit_print_usage
            exit 0
        fi
        if _knit_find_flag "-v,--version" $@; then
            echo $KNIT_VERSION
            exit 0
        fi
    fi
}
