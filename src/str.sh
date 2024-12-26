#!/bin/bash

# ------------------------------------------------------------------------------
# Function to convert hyphens to underscores
# ------------------------------------------------------------------------------
_knit_str_hyphens_to_underscores() {
  local input="$1"
  echo "${input//-/_}"
}

# ------------------------------------------------------------------------------
# Function to convert underscores to hyphens
# ------------------------------------------------------------------------------
_knit_str_underscores_to_hyphens() {
  local input="$1"
  echo "${input//_/-}"
}
