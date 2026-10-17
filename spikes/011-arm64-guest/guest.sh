echo STEP_BEGIN_ARCH $(uname -m)
nproc; free -m | head -2
T0=$(date +%s)
apk add --no-cache python3 docker 2>&1 | tail -3
echo STEP_APK_SECONDS $(( $(date +%s) - T0 ))
wget -q -O /bench.py http://10.0.2.2:18080/bench.py
echo STEP_HOST_PYTHON
python3 /bench.py
printf "auto lo\niface lo inet loopback\n" > /etc/network/interfaces
rc-service networking start 2>&1 | tail -2
T0=$(date +%s)
service docker start 2>&1 | tail -2
for i in $(seq 1 60); do docker info >/dev/null 2>&1 && break; sleep 2; done
echo STEP_DOCKER_START_SECONDS $(( $(date +%s) - T0 ))
docker version 2>&1 | grep -E "Version|OS/Arch"
T0=$(date +%s)
docker pull python:3-alpine 2>&1 | tail -3
echo STEP_PULL_SECONDS $(( $(date +%s) - T0 ))
echo STEP_CONTAINER_PYTHON
docker run --rm --network none -v /bench.py:/bench.py python:3-alpine python /bench.py
echo STEP_DONE
