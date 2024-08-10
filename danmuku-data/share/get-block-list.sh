#!/bin/bash
# Copyright (C) 2024 shmilee
#wget -c https://github.com/jnxyp/Bilibili-Block-List/releases/download/0.10.074/Latest.BBL-Main-0.10.74-Basic.xml
sed -n 's#^\s\s<item enabled="true">r=【.*】|\(.*\)</item>#\1#p' \
    ./Latest.BBL-Main-0.10.74-Basic.xml >./BBL.txt
