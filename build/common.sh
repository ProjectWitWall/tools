#!/bin/sh

# Copyright (c) 2014-2015 Franco Fichtner <franco@opnsense.org>
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
#
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
#
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
# OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
# LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
# OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
# SUCH DAMAGE.

set -e

# important build settings
export PRODUCT_NAME="OPNsense"

# build directories
export STAGEDIR="/usr/local/stage"
export PACKAGESDIR="/tmp/packages"
export IMAGESDIR="/tmp/images"
export SETSDIR="/tmp/sets"

# code reositories
export TOOLSDIR="/usr/tools"
export PORTSDIR="/usr/ports"
export COREDIR="/usr/core"
export SRCDIR="/usr/src"

# misc. foo
export CPUS=`sysctl kern.smp.cpus | awk '{ print $2 }'`
export ARCH=${ARCH:-"`uname -m`"}
export TARGETARCH=${ARCH}
export TARGET_ARCH=${ARCH}

# target files
export ISOPATH="${IMAGESDIR}/${PRODUCT_NAME}-LiveCD-${ARCH}-`date '+%Y%m%d-%H%M'`.iso"
export MEMSTICKPATH="${IMAGESDIR}/${PRODUCT_NAME}-memstick-${ARCH}-`date '+%Y%m%d-%H%M'`.img"
export MEMSTICKSERIALPATH="${IMAGESDIR}/${PRODUCT_NAME}-memstick-serial-${ARCH}-`date '+%Y%m%d-%H%M'`.img"

# print environment to showcase all of our variables
env

git_clear()
{
	# Reset the git repository into a known state by
	# enforcing a hard-reset to HEAD (so you keep your
	# selected commit, but no manual changes) and all
	# unknown files are cleared (so it looks like a
	# freshly cloned repository).

	echo -n ">>> Resetting ${1}... "

	git -C ${1} reset --hard HEAD
	git -C ${1} clean -xdqf .
}

git_describe()
{
	VERSION=$(git -C ${1} describe --abbrev=0)
	REVISION=$(git -C ${1} rev-list ${VERSION}.. --count)
	COMMENT=$(git -C ${1} rev-list HEAD --max-count=1 | cut -c1-9)
	if [ "${REVISION}" != "0" ]; then
		# must construct full version string manually
		VERSION=${VERSION}_${REVISION}
	fi

	export REPO_VERSION=${VERSION}
	export REPO_COMMENT=${COMMENT}
}

setup_clone()
{
	echo ">>> Setting up ${2} in ${1}"

	# excludes git history on purpose...
	tar -C/ -cf - --exclude=.${2}/.git .${2} | tar -C${1} -pxf -
}

setup_chroot()
{
	echo ">>> Setting up chroot in ${1}"

	cp /etc/resolv.conf ${1}/etc
	mount -t devfs devfs ${1}/dev
	chroot ${1} /etc/rc.d/ldconfig start
}

setup_base()
{
	echo ">>> Setting up world in ${1}"

	# XXX The installer is hardwired to copy
	# /home and will bail if it can't be found!
	mkdir -p ${1}/home

	(cd ${1} && tar -Jxpf ${SETSDIR}/base-*-${ARCH}.txz)
}

setup_kernel()
{
	echo ">>> Setting up kernel in ${1}"

	(cd ${1} && tar -Jxpf ${SETSDIR}/kernel-*-${ARCH}.txz)
}

setup_packages()
{
	echo ">>> Setting up packages in ${1}..."

	BASEDIR=${1}
	shift
	PKGLIST=${@}

	mkdir -p ${PACKAGESDIR}/${ARCH} ${BASEDIR}${PACKAGESDIR}/${ARCH}
	cp ${PACKAGESDIR}/${ARCH}/* ${BASEDIR}${PACKAGESDIR}/${ARCH} || true

	if [ -z "${PKGLIST}" ]; then
		# forcefully add all available packages
		pkg -c ${BASEDIR} add -f ${PACKAGESDIR}/${ARCH}/*.txz || true
	else
		# always bootstrap pkg
		PKGLIST="pkg ${PKGLIST}"

		for PKG in ${PKGLIST}; do
			# must fail if packages aren't there
			pkg -c ${BASEDIR} add ${PACKAGESDIR}/${ARCH}/${PKG}-*.txz
		done
	fi

	# keep the directory!
	rm -rf ${BASEDIR}${PACKAGESDIR}/${ARCH}/*
}

setup_platform()
{
	echo ">>> Setting up platform in ${1}..."

	# XXX clean this up:
	mkdir -p ${1}/cf/conf
	chroot ${1} /bin/ln -s /cf/conf /conf
	touch ${1}/cf/conf/trigger_initial_wizard
	echo cdrom > ${1}/usr/local/etc/platform

	# Set sane defaults via rc.conf(5)
	cat > ${1}/etc/rc.conf <<EOF
tmpmfs="YES"
tmpsize="128m"
EOF

	DEFAULT_PW=`cat ${1}/usr/local/etc/inc/globals.inc | grep factory_shipped_password | cut -d'"' -f4`
	echo ">>> Setting up initial root password: ${DEFAULT_PW}"
	chroot ${1} /bin/sh -s <<EOF
echo ${DEFAULT_PW} | pw usermod -n root -h 0
EOF
}

setup_mtree()
{
	echo ">>> Creating mtree summary of files present..."

	cat > ${1}/tmp/installed_filesystem.mtree.exclude <<EOF
./dev
./tmp
EOF
	chroot ${1} /bin/sh -s <<EOF
/usr/sbin/mtree -c -k uid,gid,mode,size,sha256digest -p / -X /tmp/installed_filesystem.mtree.exclude > /tmp/installed_filesystem.mtree
/bin/chmod 600 /tmp/installed_filesystem.mtree
/bin/mv /tmp/installed_filesystem.mtree /etc/
/bin/rm /tmp/installed_filesystem.mtree.exclude
EOF
}

setup_stage()
{
	echo ">>> Setting up stage in ${1}"

	# might have been a chroot
	umount ${1}/dev 2> /dev/null || true
	# remove base system files
	rm -rf ${1} 2> /dev/null ||
	    (chflags -R noschg ${1}; rm -rf ${1} 2> /dev/null)
	# revive directory for next run
	mkdir -p ${1}
}
