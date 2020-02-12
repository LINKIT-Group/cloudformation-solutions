
# DEBUG
echo "Environment vars:"
echo "  AWS_PROFILE=${AWS_PROFILE}"
echo "  CONFIGURATION_BUCKET=${CONFIGURATION_BUCKET}"
echo "  STACKNAME=${STACKNAME}"
echo "  WORKDIR=${WORKDIR}"
echo "  BUILDDIR=${BUILDDIR}"
# /DEBUG

function zip_sourcedir(){
    ## zip docker-codebuild -- ensure we have a fresh copy
    sourcedir="${1}"
    zipfile="${WORKDIR}"/"${BUILDDIR}"/"$(basename "${sourcedir}")".zip

    [ ! -d "${sourcedir}" ] && return 1

    if [ -s "${zipfile}" ];then
        # remove (old) zipfile if sourcedir contains an update
        # else exit -- nothing to do
        update="$(find "${sourcedir}" -type f -newer "${zipfile}" |cut -b1)"
        if [ ! -z "${update}" ];then
            rm -f "${zipfile}"
        else
            return 0
        fi
    fi

    # zip it
    (
        cd "${sourcedir}" && \
            zip -qr "${zipfile}" *
    )
}

# create artifact(s)
zip_sourcedir "docker-codebuild"

# upload artifacts to S3
artifacts="docker-codebuild.zip"
aws s3 sync \
    --profile "${AWS_PROFILE}" \
    --exclude "*" \
    --include ${artifacts} \
    "${BUILDDIR}" \
    s3://${CONFIGURATION_BUCKET}/${STACKNAME}

# NOTE: ensure vars do not contain &, " or $ chars
# ampersand and dollar-sign make sed replacement fail
# double-quote produces invalid json as it becomes part of the value
# generate parameters file
sed '/^#.*/d;
     s/{{ *S3Bucket *}}/'${CONFIGURATION_BUCKET}'/g;
     s/{{ *S3BucketPrefix *}}/'${STACKNAME}'/g; 
     s/{{ *DockerHubUsername *}}/'${DockerhubUsername}'/g; 
     s/{{ *DockerHubPassword *}}/'${DockerhubPassword}'/g' \
    parameters.ini.template >"${BUILDDIR}"/parameters.ini
