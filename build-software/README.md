
# build a docker image
docker build --no-cache --network=host --build-arg http_proxy=http://127.0.0.1:1080 --build-arg https_proxy=http://127.0.0.1:1080 -t debian13-builder .
