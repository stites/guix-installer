build:
	./build-iso.sh
resizetmpfs:
	sudo mount -o remount,size=20G /tmp
	sudo mount -o remount,size=10G /run/user/1000
