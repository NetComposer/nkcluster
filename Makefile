REPO ?= nkcluster
RELOADER ?= -s nkreloader

.PHONY: deps release dev

all: deps compile

compile:
	./rebar compile

cnodeps:
	./rebar compile skip_deps=true

deps:
	./rebar get-deps
	find deps -name "rebar.config" | xargs perl -pi -e 's/lager, "2.0.3"/lager, ".*"/g'
	(cd deps/lager && git checkout 2.1.1)

clean: 
	./rebar clean

distclean: clean
	./rebar delete-deps

tests: compile eunit

eunit:
	export ERL_FLAGS="-config test/app.config -args_file test/vm.args"; \
	./rebar eunit skip_deps=true

shell:
	erl -config util/shell_app.config -args_file util/shell_vm.args -s nkcluster_app

shell-test:
	erl -config test/app.config -args_file test/vm.args -s nkcluster_app

docs:
	./rebar skip_deps=true doc


dev1:
	erl -config util/dev1.config -args_file util/dev_vm.args \
		-name dev1@127.0.0.1 -s nkcluster_app $(RELOADER)

dev2:
	erl -config util/dev2.config -args_file util/dev_vm.args \
	    -name dev2@127.0.0.1 -s nkcluster_app $(RELOADER)

dev3:
	erl -config util/dev3.config -args_file util/dev_vm.args \
	    -name dev3@127.0.0.1 -s nkcluster_app $(RELOADER)

dev4:
	erl -config util/dev4.config -args_file util/dev_vm.args \
	    -name dev4@127.0.0.1 -s nkcluster_app $(RELOADER)

dev5:
	erl -config util/dev5.config -args_file util/dev_vm.args \
	    -name dev5@127.0.0.1 -s nkcluster_app $(RELOADER)

dev:
	erl -config test/app.config -args_file test/vm.args \
	    -s nkcluster_app $(RELOADER)



APPS = kernel stdlib sasl erts ssl tools os_mon runtime_tools crypto inets \
	xmerl webtool snmp public_key mnesia eunit syntax_tools compiler
COMBO_PLT = $(HOME)/.$(REPO)_combo_dialyzer_plt

check_plt: 
	dialyzer --check_plt --plt $(COMBO_PLT) --apps $(APPS) deps/*/ebin

build_plt: 
	dialyzer --build_plt --output_plt $(COMBO_PLT) --apps $(APPS) deps/nk*/ebin

dialyzer:
	dialyzer -Wno_return --plt $(COMBO_PLT) ebin/nkcluster*.beam #| \
	    # fgrep -v -f ./dialyzer.ignore-warnings

cleanplt:
	@echo 
	@echo "Are you sure?  It takes about 1/2 hour to re-build."
	@echo Deleting $(COMBO_PLT) in 5 seconds.
	@echo 
	sleep 5
	rm $(COMBO_PLT)


build_tests:
	erlc -pa ebin -pa deps/lager/ebin -o ebin -I include -pa deps/nklib \
	+export_all +debug_info +"{parse_transform, lager_transform}" \
	test/*.erl
