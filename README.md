# unattended-pi-setup
Files and instructions for unattended/automatic setup of a Raspberry Pi using only the boot partition which you can see on a flashed SD card on windows.

This project borrows quite heavily from Jim Danner on GitLab: https://gitlab.com/JimDanner/pi-boot-script/-/tree/master

I could never get his version working properly, I made a lot of changes and wanted to share them here.

init=/bin/bash -c "mount -t proc proc /proc; mount -t sysfs sys /sys; mount /boot; source /boot/unattended"


Tested on Rpi4 and Pi Zero W
With Raspberry Pi OS - Release date: May 7th 2021
