#!/bin/bash

## @file str.sh

# ------------------------------------------------------------------------------
# @fn _knit_str_hyphens_to_underscores()
#
# Function to convert hyphens to underscores
# ------------------------------------------------------------------------------
_knit_str_hyphens_to_underscores() {
  local input="$1"
  echo "${input//-/_}"
}

# ------------------------------------------------------------------------------
# @fn _knit_str_underscores_to_hyphens()
#
# Function to convert underscores to hyphens
# ------------------------------------------------------------------------------
_knit_str_underscores_to_hyphens() {
  local input="$1"
  echo "${input//_/-}"
}
