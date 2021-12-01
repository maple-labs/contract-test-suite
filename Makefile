ci          :; ./build.sh -c ./config/ci.json
clean       :; dapp clean
dev         :; ./build.sh -c ./config/dev.json
init        :; dapp update ; chmod +x test.sh ; cd cache/cts-cache ; git checkout master ; git pull ; cd ../..
reset-cache :; rm -rf cache/cts-cache && dapp --make-cache cache/cts-cache
update      :; ./update-cache.sh
test        :; ./test.sh
