load(":json_parser.bzl", "json_parse")

# Because Poetry doesn't add several packages in the poetry.lock file,
# they are excluded from the list of packages.
# See https://github.com/python-poetry/poetry/blob/d2fd581c9a856a5c4e60a25acb95d06d2a963cf2/poetry/puzzle/provider.py#L55
# and https://github.com/python-poetry/poetry/issues/1584
POETRY_UNSAFE_PACKAGES = ["setuptools", "distribute", "pip", "wheel"]

def _clean_name(name):
    return name.lower().replace("-", "_").replace(".", "_")

def _mapping(repository_ctx):
    result = repository_ctx.execute(
        [
            repository_ctx.attr.python_interpreter,
            repository_ctx.path(repository_ctx.attr._script),
            "-i",
            repository_ctx.path(repository_ctx.attr.pyproject),
            "-o",
            "-",
            "--if",
            "toml",
            "--of",
            "json",
        ],
    )

    if result.return_code:
        fail("remarshal failed: %s (%s)" % (result.stdout, result.stderr))

    pyproject = json_parse(result.stdout)
    return {
        dep.lower(): "@%s//:library_%s" % (repository_ctx.name, _clean_name(dep))
        for dep in pyproject["tool"]["poetry"]["dependencies"].keys()
    }

def _dev_mapping(repository_ctx):
    result = repository_ctx.execute(
        [
            repository_ctx.attr.python_interpreter,
            repository_ctx.path(repository_ctx.attr._script),
            "-i",
            repository_ctx.path(repository_ctx.attr.pyproject),
            "-o",
            "-",
            "--if",
            "toml",
            "--of",
            "json",
        ],
    )

    if result.return_code:
        fail("remarshal failed: %s (%s)" % (result.stdout, result.stderr))

    pyproject = json_parse(result.stdout)
    return {
        dep.lower(): "@%s//:library_%s" % (repository_ctx.name, _clean_name(dep))
        for dep in pyproject["tool"]["poetry"]["dev-dependencies"].keys()
    }

def _impl(repository_ctx):
    mapping = _mapping(repository_ctx)
    dev_mapping = _dev_mapping(repository_ctx)

    result = repository_ctx.execute(
        [
            repository_ctx.attr.python_interpreter,
            repository_ctx.path(repository_ctx.attr._script),
            "-i",
            repository_ctx.path(repository_ctx.attr.lockfile),
            "-o",
            "-",
            "--if",
            "toml",
            "--of",
            "json",
        ],
    )

    if result.return_code:
        fail("remarshal failed: %s (%s)" % (result.stdout, result.stderr))

    lockfile = json_parse(result.stdout)
    metadata = lockfile["metadata"]
    if "files" in metadata:  # Poetry 1.x format
        files = metadata["files"]

        # only the hashes are needed to build a requirements.txt
        hashes = {
            k: [x["hash"] for x in v]
            for k, v in files.items()
        }
    elif "hashes" in metadata:  # Poetry 0.x format
        hashes = ["sha256:" + h for h in metadata["hashes"]]
    else:
        fail("Did not find file hashes in poetry.lock file")

    # using a `dict` since there is no `set` type
    excludes = {x.lower(): True for x in repository_ctx.attr.excludes + POETRY_UNSAFE_PACKAGES}

    # TODO (sseveran): Should we also check dev mappings for excludes
    for requested in mapping:
        if requested.lower() in excludes:
            fail("pyproject.toml dependency {} is also in the excludes list".format(requested))

    packages = []
    for package in lockfile["package"]:
        name = package["name"]

        if name.lower() in excludes:
            continue

        if "source" in package and package["source"]["type"] != "legacy":
            # TODO: figure out how to deal with git and directory refs
            print("Skipping " + name)
            continue

        packages.append(struct(
            name = _clean_name(name),
            pkg = name,
            version = package["version"],
            hashes = hashes[name],
            marker = package.get("marker", None),
            source_url = package.get("source", {}).get("url", None),
            dependencies = [
                _clean_name(name)
                for name in package.get("dependencies", {}).keys()
                if name.lower() not in excludes
            ],
        ))

    repository_ctx.file(
        "dependencies.bzl",
        """
_mapping = {mapping}
_dev_mapping = {dev_mapping}

def dependency(name):
    if name not in _mapping:
        fail("%s is not present in pyproject.toml as a dependency" % name)

    return _mapping[name]

def dev_dependency(name):
    if name not in _dev_mapping:
        fail("%s is not present in pyproject.toml as a dev-dependency" % name)

    return _dev_mapping[name]
""".format(mapping = mapping, dev_mapping = dev_mapping),
    )

    repository_ctx.symlink(repository_ctx.path(repository_ctx.attr._rules), repository_ctx.path("defs.bzl"))

    poetry_template = """
download_wheel(
    name = "wheel_{name}",
    pkg = "{pkg}",
    version = "{version}",
    hashes = {hashes},
    marker = "{marker}",
    source_url = "{source_url}",
    visibility = ["//visibility:private"],
    tags = [{download_tags}, "requires-network"],
)

pip_install(
    name = "install_{name}",
    wheel = ":wheel_{name}",
    tags = [{install_tags}],
)

py_library(
    name = "library_{name}",
    srcs = glob(["{pkg}/**/*.py"]),
    data = glob(["{pkg}/**/*"], exclude=["**/*.py", "**/* *", "BUILD", "WORKSPACE"]),
    imports = ["{pkg}"],
    deps = {dependencies},
    visibility = ["//visibility:public"],
)
"""

    build_content = """
load("//:defs.bzl", "download_wheel")
load("//:defs.bzl", "noop")
load("//:defs.bzl", "pip_install")
"""

    install_tags = ["\"{}\"".format(tag) for tag in repository_ctx.attr.tags]
    download_tags = install_tags + ["\"requires-network\""]

    for package in packages:
        build_content += poetry_template.format(
            name = _clean_name(package.name),
            pkg = package.pkg,
            version = package.version,
            hashes = package.hashes,
            marker = package.marker or "",
            source_url = package.source_url or "",
            install_tags = ", ".join(install_tags),
            download_tags = ", ".join(download_tags),
            dependencies = [":install_%s" % _clean_name(package.name)] +
                           [":library_%s" % _clean_name(dep) for dep in package.dependencies],
        )

    excludes_template = """
noop(
    name = "library_{name}",
)
    """

    for package in excludes:
        build_content += excludes_template.format(
            name = _clean_name(package),
        )

    repository_ctx.file("BUILD", build_content)

poetry = repository_rule(
    attrs = {
        "pyproject": attr.label(
            mandatory = True,
            allow_single_file = True,
        ),
        "lockfile": attr.label(
            mandatory = True,
            allow_single_file = True,
        ),
        "excludes": attr.string_list(
            mandatory = False,
            allow_empty = True,
            default = [],
            doc = "List of packages to exclude, useful for skipping invalid dependencies",
        ),
        "python_interpreter": attr.string(
            mandatory = False,
            default = "python3",
            doc = "The command to run the Python interpreter used during repository setup",
        ),
        "_rules": attr.label(
            default = ":defs.bzl",
        ),
        "_script": attr.label(
            executable = True,
            default = "//tools:remarshal.par",
            cfg = "host",
        ),
    },
    implementation = _impl,
    local = False,
)
