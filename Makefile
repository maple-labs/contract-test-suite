dev         :; ./build.sh -c ./config/dev.json
ci          :; ./build.sh -c ./config/ci.json
clean       :; dapp clean
setup-cache :; dapp --make-cache cache/cts-cache
reset-cache :; rm -rf cache/cts-cache && dapp --make-cache cache/cts-cache
update      :; ./update-cache.sh
test        :; ./test.sh
