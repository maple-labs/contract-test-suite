ci           :; ./build.sh -c ./config/ci.json
clean        :; dapp clean
dev          :; ./build.sh -c ./config/dev.json
init         :; dapp update && chmod +x reset-cache.sh && make reset-cache
reset-cache  :; ./reset-cache.sh
test         :; ./test.sh
update-cache :; ./update-cache.sh
