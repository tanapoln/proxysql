FROM debian:13 AS plugin-builder

RUN apt-get update && \
	apt-get install -y \
	g++ \
	libldap-dev \
	libssl-dev && \
	rm -rf /var/lib/apt/lists/*

COPY include/Okta_LDAP_Plugin.h \
	include/MySQL_LDAP_Authentication.hpp \
	include/sqlite3db.h \
	/src/include/
COPY deps/sqlite3/sqlite-amalgamation-*/sqlite3.h /src/deps/sqlite3/sqlite3/
COPY lib/Okta_LDAP_Plugin.cpp /src/lib/

RUN g++ -std=c++17 -fPIC -O2 -Wall \
	-I/src/include \
	-I/src/deps/sqlite3/sqlite3 \
	-shared \
	-Wl,-soname,proxysql_okta_ldap_auth.so \
	-Wl,--allow-shlib-undefined \
	-o /proxysql_okta_ldap_auth.so \
	/src/lib/Okta_LDAP_Plugin.cpp \
	-lldap -llber -lssl -lcrypto -lpthread


FROM debian:13

ARG TARGETARCH
ARG RELEASE_TAG=v3.0-head
ARG RELEASE_REPO=tanapoln/proxysql
ARG DEB_VERSION=3.0.6

RUN cat /etc/os-release

RUN apt-get update && \
	apt-get install -y apt-utils

RUN apt-get install -y \
	default-mysql-client \
	postgresql-client \
	wget \
	ca-certificates \
	curl

# Download and install pre-built ProxySQL .deb from GitHub release
RUN ARCH=$([ "$TARGETARCH" = "arm64" ] && echo "arm64" || echo "amd64") && \
	DEB_NAME="proxysql_${DEB_VERSION}-debian13_${ARCH}.deb" && \
	echo "Downloading: ${DEB_NAME} from ${RELEASE_REPO}@${RELEASE_TAG}" && \
	curl -fsSL -o /tmp/proxysql.deb \
		"https://github.com/${RELEASE_REPO}/releases/download/${RELEASE_TAG}/${DEB_NAME}" && \
	dpkg -i /tmp/proxysql.deb || apt-get install -f -y && \
	rm -f /tmp/proxysql.deb

# Install LDAP plugin built from source
RUN mkdir -p /usr/lib/proxysql
COPY --from=plugin-builder /proxysql_okta_ldap_auth.so /usr/lib/proxysql/proxysql_okta_ldap_auth.so

# clean apt cache
RUN apt clean && \
	rm -rf /var/cache/apt/* && \
	rm -rf /var/lib/apt/lists/*


CMD ["proxysql", "-f", "--idle-threads", "-D", "/var/lib/proxysql"]
