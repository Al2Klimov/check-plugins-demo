FROM debian:9

SHELL ["/bin/bash", "-exo", "pipefail", "-c"]

RUN apt-get update ;\
	DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends --no-install-suggests -y \
	icinga2-{bin,ido-mysql} dbconfig-no-thanks mariadb-server \
	apache2 icingaweb2{,-module-monitoring} php7.0-{intl,imagick,mysql} locales \
	influxdb ;\
	apt-get clean ;\
	rm -vrf /var/lib/apt/lists/* /etc/icinga2/conf.d/* /etc/icingaweb2/* ;\
	perl -pi -e 's~//~~' /etc/icinga2/features-available/influxdb.conf ;\
	perl -pi -e 'if (!%locales) { %locales = (); for my $d ("", "/modules/monitoring") { for my $f (glob "/usr/share/icingaweb2${d}/application/locale/*_*") { if ($f =~ m~/(\w+)$~) { $locales{$1} = undef } } } } s/^# ?// if (/ UTF-8$/ && /^# (\w+)/ && exists $locales{$1})' /etc/locale.gen

COPY --from=grandmaster/nosu:latest /usr/local/bin/nosu /usr/local/bin/nosu

RUN . /usr/lib/icinga2/icinga2 ;\
	. /etc/default/icinga2 ;\
	/usr/lib/icinga2/prepare-dirs /usr/lib/icinga2/icinga2

RUN install -m 755 -o mysql -g root -d /var/run/mysqld

RUN mysqld -u mysql & \
	MYSQLD_PID="$!" ;\
	while ! mysql <<<''; do sleep 1; done ;\
	mysql <<<"CREATE DATABASE icinga2; USE icinga2; $(< /usr/share/icinga2-ido-mysql/schema/mysql.sql) GRANT ALL ON icinga2.* TO nagios@localhost IDENTIFIED VIA unix_socket; GRANT SELECT ON icinga2.* TO 'www-data'@localhost IDENTIFIED VIA unix_socket;" ;\
	kill "$MYSQLD_PID" ;\
	while test -e "/proc/$MYSQLD_PID"; do sleep 1; done

RUN nosu influxdb influxdb influxd -config /etc/influxdb/influxdb.conf & \
	INFLUXD_PID="$!" ;\
	while ! perl -e 'use IO::Socket; IO::Socket::INET->new("127.0.0.1:8086") or die $@'; do sleep 1; done ;\
	perl -e 'use IO::Socket; for my $q ("create+database+icinga2", "create+user+icinga2+with+password+%27icinga2%27", "grant+all+on+icinga2+to+icinga2") { my $s = IO::Socket::INET->new("127.0.0.1:8086") or die $@; $s->send("POST /query?chunked=true&db=&epoch=ns&q=${q} HTTP/1.0\r\nHost: localhost:8086\r\nUser-Agent: InfluxDBShell/1.0.2\r\nContent-Length: 0\r\n\r\n") or die $@; sleep 1 }' ;\
	kill "$INFLUXD_PID" ;\
	while test -e "/proc/$INFLUXD_PID"; do sleep 1; done

COPY icinga2-ido.conf /etc/icinga2/features-available/ido-mysql.conf

RUN . /usr/lib/icinga2/icinga2 ;\
	. /etc/default/icinga2 ;\
	for f in command influxdb ido-mysql; do icinga2 feature enable $f; done

COPY php-icingaweb2.ini /etc/php/7.0/apache2/conf.d/99-icingaweb2.ini
COPY apache2-icingaweb2.conf /etc/apache2/conf-available/icingaweb2-ext.conf
RUN a2enconf icingaweb2-ext
RUN install -o root -g icingaweb2 -m 02770 -d /var/log/icingaweb2
ADD --chown=www-data:icingaweb2 icingaweb2 /etc/icingaweb2
RUN install -o www-data -g icingaweb2 -m 02770 -d /etc/icingaweb2/enabledModules
RUN ln -vs /usr/share/icingaweb2/modules/monitoring /etc/icingaweb2/enabledModules/monitoring
RUN locale-gen -j 4

COPY --from=ochinchina/supervisord:latest /usr/local/bin/supervisord /usr/local/bin/supervisord
COPY supervisord.conf /supervisord.conf
CMD ["/usr/local/bin/supervisord", "-c", "/supervisord.conf"]
