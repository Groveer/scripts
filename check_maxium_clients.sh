#!/bin/bash

sudo ss -x src "*/tmp/.X11-unix/*" | grep -Eo "[0-9]+\s*$" | while read port
do
  sudo ss -p -x | grep -w $port | grep -v X11-unix
done | grep -Eo '".+"' | sort | uniq -c | sort -rn

