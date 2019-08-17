FROM debian:10

SHELL ["/bin/bash", "-exo", "pipefail", "-c"]

RUN apt-get update ;\
	DEBIAN_FRONTEND=noninteractive apt-get install --no-install-{recommends,suggests} -y \
		apt-transport-https gnupg2 dirmngr ca-certificates ;\
	apt-get clean ;\
	rm -vrf /var/lib/apt/lists/* ;\
	apt-key adv --fetch-keys \
		'https://packages.icinga.com/icinga.key' \
		'https://repos.influxdata.com/influxdb.key' \
		'https://packages.grafana.com/gpg.key' ;\
	DEBIAN_FRONTEND=noninteractive apt-get purge -y gnupg2 dirmngr ;\
	DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y

ADD apt-ext.list /etc/apt/sources.list.d/ext.list

RUN apt-get update ;\
	DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends --no-install-suggests -y \
	icinga2-{bin,ido-mysql} dbconfig-no-thanks mariadb-server \
	apache2 icingaweb2{,-module-monitoring} php7.3-{intl,imagick,mysql,curl} locales \
	influxdb grafana git ;\
	pushd /usr/share/icingaweb2/modules ;\
	git clone https://github.com/Mikesch-mp/icingaweb2-module-grafana.git grafana ;\
	pushd grafana ;\
	git checkout dfce2c20708442d558ee90c5c3287bbdf624c435 ;\
	rm -rf .git ;\
	popd ;\
	popd ;\
	DEBIAN_FRONTEND=noninteractive apt-get purge -y git ;\
	DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y ;\
	apt-get clean ;\
	rm -vrf /var/lib/apt/lists/* /etc/icinga2/conf.d/* /etc/icingaweb2/* ;\
	a2dissite 000-default ;\
	perl -pi -e 's~//~~ if /const NodeName/' /etc/icinga2/constants.conf ;\
	perl -pi -e 's~//~~' /etc/icinga2/features-available/influxdb.conf ;\
	perl -pi -e 'if (!%locales) { %locales = (); for my $d ("", "/modules/monitoring") { for my $f (glob "/usr/share/icingaweb2${d}/application/locale/*_*") { if ($f =~ m~/(\w+)$~) { $locales{$1} = undef } } } } s/^# ?// if (/ UTF-8$/ && /^# (\w+)/ && exists $locales{$1})' /etc/locale.gen

COPY --from=grandmaster/nosu:latest /usr/local/bin/nosu /usr/local/bin/nosu

RUN set -a; . /etc/default/icinga2; set +a ;\
	/usr/lib/icinga2/prepare-dirs /etc/default/icinga2

RUN install -m 755 -o mysql -g root -d /var/run/mysqld

COPY grafana.ini /etc/grafana/
RUN install -o grafana -g grafana -d /var/run/grafana

RUN mysqld -u mysql & \
	MYSQLD_PID="$!" ;\
	while ! mysql <<<''; do sleep 1; done ;\
	mysql <<<"CREATE DATABASE icinga2; USE icinga2; $(< /usr/share/icinga2-ido-mysql/schema/mysql.sql) GRANT ALL ON icinga2.* TO nagios@localhost IDENTIFIED VIA unix_socket; GRANT SELECT ON icinga2.* TO 'www-data'@localhost IDENTIFIED VIA unix_socket;" ;\
	kill "$MYSQLD_PID" ;\
	while test -e "/proc/$MYSQLD_PID"; do sleep 1; done

RUN bash -exo pipefail -c 'set -a; . /etc/default/influxdb; set +a; exec nosu influxdb influxdb influxd -config /etc/influxdb/influxdb.conf $INFLUXD_OPTS' & \
	INFLUXD_PID="$!" ;\
	while ! perl -e 'use IO::Socket; IO::Socket::INET->new("127.0.0.1:8086") or die $@'; do sleep 1; done ;\
	perl -e 'use IO::Socket; for my $q ("create+database+icinga2", "create+user+icinga2+with+password+%27icinga2%27", "grant+all+on+icinga2+to+icinga2") { my $s = IO::Socket::INET->new("127.0.0.1:8086") or die $@; $s->send("POST /query?chunked=true&db=&epoch=ns&q=${q} HTTP/1.0\r\nHost: localhost:8086\r\nUser-Agent: InfluxDBShell/1.0.2\r\nContent-Length: 0\r\n\r\n") or die $@; sleep 1 }' ;\
	kill "$INFLUXD_PID" ;\
	while test -e "/proc/$INFLUXD_PID"; do sleep 1; done

RUN bash -exo pipefail -c 'cd /usr/share/grafana; set -a; . /etc/default/grafana-server; set +a; exec nosu grafana grafana grafana-server "--config=$CONF_FILE" "--pidfile=/var/run/grafana/grafana-server.pid" "cfg:default.paths.logs=$LOG_DIR" "cfg:default.paths.data=$DATA_DIR" "cfg:default.paths.plugins=$PLUGINS_DIR" "cfg:default.paths.provisioning=$PROVISIONING_CFG_DIR"' & \
	GRAFANA_PID="$!" ;\
	while ! perl -e 'use IO::Socket; IO::Socket::INET->new("127.0.0.1:3000") or die $@'; do sleep 1; done ;\
	perl -e 'use IO::Socket; { local $/ = undef; local @ARGV = ("/usr/share/icingaweb2/modules/grafana/dashboards/influxdb/icinga2-default.json"); $db1 = <> } for my $r (["datasources", "{\"name\":\"Icinga 2\",\"type\":\"influxdb\",\"url\":\"http://127.0.0.1:8086\",\"access\":\"proxy\",\"jsonData\":{},\"isDefault\":true,\"database\":\"icinga2\",\"user\":\"icinga2\",\"password\":\"icinga2\"}"], ["dashboards/db", "{\"dashboard\":".($db1 =~ s/"\$\{DS_ICINGA2\}"/null/gr).",\"folderId\":0,\"overwrite\":false}"]) { my $s = IO::Socket::INET->new("127.0.0.1:3000") or die $@; $s->send("POST /api/".${$r}[0]." HTTP/1.0\r\nAccept: application/json\r\nContent-Type: application/json\r\nContent-Length: ".length(${$r}[1])."\r\n\r\n".${$r}[1]) or die $@; sleep 1 }' ;\
	kill "$GRAFANA_PID" ;\
	while test -e "/proc/$GRAFANA_PID"; do sleep 1; done

COPY icinga2-ido.conf /etc/icinga2/features-available/ido-mysql.conf

RUN set -a; . /etc/default/icinga2; set +a ;\
	for f in command influxdb ido-mysql; do icinga2 feature enable $f; done

COPY php-icingaweb2.ini /etc/php/7.3/apache2/conf.d/99-icingaweb2.ini
ADD --chown=www-data:icingaweb2 icingaweb2 /etc/icingaweb2

RUN install -o root -g icingaweb2 -m 02770 -d /var/log/icingaweb2 ;\
	install -o www-data -g icingaweb2 -m 02770 -d /etc/icingaweb2/enabledModules ;\
	ln -vs /usr/share/icingaweb2/modules/monitoring /etc/icingaweb2/enabledModules/monitoring ;\
	ln -vs /usr/share/icingaweb2/modules/grafana /etc/icingaweb2/enabledModules/grafana ;\
	locale-gen -j 4

COPY apache2-site.conf /etc/apache2/sites-available/check-plugins-demo.conf
RUN mkdir -p /etc/apache2/sites-available/check-plugins-demo.d ;\
	a2enmod proxy; a2enmod proxy_http; a2ensite check-plugins-demo

COPY --from=ochinchina/supervisord:latest /usr/local/bin/supervisord /usr/local/bin/supervisord
RUN mkdir -p /etc/supervisord/conf.d
COPY supervisord.conf /etc/supervisord/
CMD ["/usr/local/bin/supervisord", "-c", "/etc/supervisord/supervisord.conf"]
