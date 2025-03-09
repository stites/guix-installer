build:
	./build-iso.sh
test:
	guix time-machine -C './guix/channels.scm' --substitute-urls='https://ci.guix.gnu.org https://bordeaux.guix.gnu.org https://substitutes.nonguix.org' -- package -K -v3 -L $(PWD)/modules -f ./guix/test.scm
resizetmpfs:
	sudo mount -o remount,size=20G /tmp
	sudo mount -o remount,size=10G /run/user/1000
dd:
	dd if=$(IF) of=$(OF) status=progress bs=4096
	sync

