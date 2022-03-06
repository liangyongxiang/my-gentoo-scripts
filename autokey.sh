#!/bin/bash

set -x
#location=/home/yongxiang/riscv-work/gentoo-git
location=/var/db/repos/gentoo

do_key() {
    local ebuild_file=$1
    if [ ! -f "$ebuild_file" ] ;then
        echo "err nofile: "$ebuild_file""
        exit 1
    fi

    ekeyword ~riscv "$ebuild_file"
    if [ $? -ne 0 ]; then
        echo "err keyword: $ebuild_file"
        exit 2
    fi
}

exit_and_clean() {
    #git -C "$location" reset .
    #git -C "$location" checkout .
    exit $1
}

emerge_and_dokey() {
    local packagename=$@
    local last_packagename

    while : ; do
        local output=$(emerge --verbose y --color y --jobs --changed-use --autounmask-write ${packagename} 2>&1 | tee /dev/tty )
        local build_error=$(echo $"output" | grep 'If you need support')
        if [ ! -z ${build_error} ]; then
            exit_and_clean 1
        fi
        local package_missing_keyword=$(echo "$output" | grep 'missing keyword' | head -n 1 | cut -d ' ' -f 2)
        if [ -z ${package_missing_keyword} ]; then
            break
        fi
        echo "$package_missing_keyword"
        if [ "${last_packagename}" = "${package_missing_keyword}" ]; then
            echo "err keyword same files : ${last_packagename}"
            exit_and_clean 2
        fi

        # package_missing_keyword : sys-libs/libixp-0.5_p20110208-r3::gentoo
        local missing_packagename=$(qatom -F "%{CATEGORY}/%{PN}" ${package_missing_keyword})
        local equery_output=$(equery --quiet list --portage-tree --format='$category/$name/$name-$fullversion.ebuild $keywords' $missing_packagename | tac)
        # output:
        # sys-devel/clang/clang-14.0.0.9999.ebuild
        # sys-devel/clang/clang-13.0.0.9999.ebuild
        # sys-devel/clang/clang-13.0.0_rc3.ebuild
        # sys-devel/clang/clang-13.0.0_rc2.ebuild
        # sys-devel/clang/clang-12.0.1.ebuild amd64 arm arm64 ~ppc ppc64 ~riscv ~sparc x86 ~amd64-linux ~x64-macos
        # sys-devel/clang/clang-11.1.0.ebuild amd64 arm arm64 ppc64 ~riscv x86 ~amd64-linux ~x64-macos
        # sys-devel/clang/clang-10.0.1.ebuild amd64 arm arm64 ppc64 x86 ~amd64-linux

        local ebuild_file
        while IFS= read -r line; do
            keyword=$(echo "${line}" | cut -d' ' -f 2)
            if [ ! -z "${keyword}" ]; then
                ebuild_file=$(echo "${line}" | cut -d' ' -f 1)
                break
            fi
        done <<< "$equery_output"
        #ebuild_file = sys-devel/clang/clang-12.0.1.ebuild

        do_key "${location}/${ebuild_file}"

        last_packagename="${package_missing_keyword}"
    done
}

package_append_all_use() {
    local filename=$(basename $1)
    local finish=1
    local all_modified=$(git -C "$location" status | grep 'modified:')
    if [ ! -z "$all_modified" ]; then
        local packages=$(echo "$all_modified" | tr -s ' ' | cut -d' ' -f 2 | xargs dirname)
        while IFS= read -r package; do
            local uses=$(equery --quiet uses "$package" | grep -vE '(^\+|-python_target|python_single_target|ruby_target|lua_target|lua_signel_target|minimal)' | cut -c 2- | tr '\n' ' ')
            if [ ! -z "${uses}" ]; then
                echo "${package} ${uses}" >> "/etc/portage/package.use/$filename"
                finish=1
            fi
        done <<< $(echo "$all_modified" | tr -s ' ' | cut -d' ' -f 2 | xargs dirname)
    fi

    return $finish
}

repoman_check_and_commit() {
    local packagename=$1

    # change if keyword=riscv changed
    LIN=$(git -C "$location" diff $packagename | wc -l)
    if [ ${LIN} -eq 0 ]; then
        LIN=$(git -C "$location" diff --staged $packagename | wc -l)
        if [ ${LIN} -eq 0 ]; then
            echo "err nochange: $packagename"
            return 0
        fi
    fi

    repoman full -dx -j $(nproc)
    if [ $? -ne 0 ]; then
        echo "err check: $packagename"
        exit_and_clean 3
    fi

    echo "repoman commit -m \"${packagename}: keyword ~riscv\""
    repoman commit -m "${packagename}: keyword ~riscv"
    if [ $? -ne 0 ]; then
        echo "err check: $packagename"
        exit_and_clean 4
    fi
    echo "success: $packagename"

    return 0
}

repoman_check_and_commit_all() {
    local all_modified=$(git -C "$location" status | grep 'modified:')
    if [ ! -z "$all_modified" ]; then
        local all_diff=$(echo "$all_modified" | tr -s ' ' | cut -d' ' -f 2 | xargs dirname)
        while IFS= read -r packagename; do
            pushd "${location}/${packagename}"
            repoman_check_and_commit $packagename
            popd
        done <<< $all_diff
    fi
}

emerge_autokeyword() {

    while : ; do
        emerge_and_dokey $@
        [[ -z apply_all_uses ]] && package_append_all_use $1 || break
    done

    repoman_check_and_commit_all

    exit 0
}

if [ $1 = '-u' ]; then
    apply_all_uses=1
    shift
else
    apply_all_uses=0
fi

cd "${location}"
emerge_autokeyword $@
