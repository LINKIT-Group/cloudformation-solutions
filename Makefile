# --------------------------------------------------------------------
# Copyright (c) 2020 Anthony Potappel - LINKIT, The Netherlands.
# SPDX-License-Identifier: MIT
# --------------------------------------------------------------------
# This file is auto-generated from: tools/cfn-makefile
# Manual changes are overwritten at each update
# --------------------------------------------------------------------

SHELL := /bin/bash
NAME := CloudFormation Makefile
VERSION := 0.92-1580468200300
DATE := 2020-01-31T10:56:40.299912+00:00

# profile=
_AWS_PROFILE = \
	$(if $(profile),$(profile),$(if $(AWS_PROFILE),$(AWS_PROFILE),default))

_GIT_REPOSITORY = $(if $(git),$(git),)


.PHONY: help
help: show_help
	@# target: help


.PHONY: deploy
deploy: set_environment pre_process stack post_process
	@# target: deploy
	@#  main target, deploy or update a stack via dependency targets:
	@#  set_environment, pre_process, stack and post_process
	@echo Deployed succesfully: $(_DEPLOYSTACK)


.PHONY: stack
stack: read_configuration package
	@# target: stack
	@#  ensure configuration is read, and stack is packaged
	@#	then deploys stack via AWS CLI
	@# verify if Configuration Outputs are complete and non-empty
	@([ ! -z $(ArtifactBucket) ] && [ ! -z $(IAMServiceRole) ]) || \
		(echo "Configuration Outputs incomplete"; exit 1)
	@# deploy Stack -- include parameters.ini if file exists
	( \
		[ -s "$(_BUILDDIR)"/parameters.ini ] && \
			params=--parameter-overrides\ $$(cat "$(_BUILDDIR)"/parameters.ini); \
		aws cloudformation deploy \
			--profile $(_AWS_PROFILE) \
	        --stack-name $(_DEPLOYSTACK) \
			--role-arn $(IAMServiceRole) \
			--template-file $(_BUILDDIR)/template.yaml \
	        --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
			--tags \
				_CONFIGSTACK="$(_CONFIGSTACK)" \
				_GIT_REPOSITORY="$(if $(_GIT_REPOSITORY),$(_GIT_REPOSITORY),None)" \
			$${params} \
	)


.PHONY: set_workdir
set_workdir:
	@# target: set_workdir
	@#   setup a workingspace in ${PATH_OF_THIS_MAKEFILE}/.build
	$(eval _WORKDIR = $(shell \
    	cd $$(dirname "$${BASH_SOURCE[0]}" || echo ".") && pwd || echo ""))
	@[ -d .build ] || mkdir .build
	@tmpfile=.build/tmpfile; \
	   cat <<< "$${GIT_IGNORE}" >$${tmpfile}; \
	   sh $${tmpfile}; \
	   rm $${tmpfile}
	@cat <<< "$${CFN_FUNCTIONS}" >.build/cfn_functions.sh
	@cat <<< "$${GIT_FUNCTIONS}" >.build/git_functions.sh


.PHONY: set_environment_local
set_environment_local: set_workdir
	@# target: set_environment_local
	@#   _TEMPLATE points to a CloudFormation Template -- typically a Rootstack
	@#   set by passing template=${path} -- defaults to template.yaml
	@#   _TEMPLATE_ROOT points to the directory where _TEMPLATE is located
	$(eval _TEMPLATE = $(if $(template),$(template),template.yaml))
	$(eval _TEMPLATE_ROOT = $(shell dirname "$(_TEMPLATE)"))
ifneq ($(_GIT_REPOSITORY),)
	@# if git=${repository} is passed, pull from repository into .build/_GIT_ROOT
	@# can be used together with template={path} -- ${path} starts from _GIT_ROOT
	$(git-env) pull_from_git "$(_GIT_REPOSITORY)" "$(_WORKDIR)"
	$(eval _GIT_ROOT = $(shell \
		$(git-env) printf "$$(git_namestring "$(_GIT_REPOSITORY)" "$(_WORKDIR)")" \
	))
	$(if $(_GIT_ROOT),,$(error _GIT_ROOT))
	@# reconstruct _TEMPLATE_ROOT by putting _GIT_ROOT in front of it
	@# if no template={path} is given the latter (shell printf) part must be empty
	# feed_GIT_COMMIT to derive_stackname so it can be pushed to the end
	$(eval _TEMPLATE_ROOT = .build/$(_GIT_ROOT)$(shell \
		printf "$$(printf "$(_TEMPLATE_ROOT)" \
				   |sed 's/^[\/]*/\//g;s/^[\/\.]*$$//g')" \
	))
	@# idem. to _TEMPLATE
	$(eval _TEMPLATE = $(_TEMPLATE_ROOT)/$(shell \
		basename "$(_TEMPLATE)"))
endif


.PHONY: set_environment_aws
set_environment_aws: set_workdir set_environment_local
	@# target: set_environment_aws
	@#   define name of _DEPLOYSTACK and _CONFIGSTACK based on _USERID and template
	@#   location (_TEMPLATE_ROOT). If sourced from GIT, append branchname and commit
	@# get last 8 chars of USERID
	$(eval _USERID = $(if $(userid),$(userid),$(shell \
        aws sts get-caller-identity \
          --query UserId \
          --output text \
          --profile "$(_AWS_PROFILE)" \
        |sed 's/:.*//g;s/None//g;s/[^a-zA-Z0-9_]//g' \
		|awk '{print substr($$0,length($$0) - 7,8)}' \
	)))
	$(if $(_USERID),,$(error _USERID))
	@# if stackname={} option is passed: use this name for DEPLOYSTACK
	@# else derive stackname from TEMPLATE_ROOT
	$(eval _DEPLOYSTACK = $(if $(stackname),$(stackname),$(shell \
	 	$(cfn-env) derive_stackname "$(_TEMPLATE_ROOT)" "$(_GIT_ROOT)" "$(_WORKDIR)" "$(_USERID)" \
	)))
	$(if $(_DEPLOYSTACK),,$(error _DEPLOYSTACK))
	$(eval _BUILDDIR = .build/$(_DEPLOYSTACK))
	$(eval _CONFIGSTACK = ConfigStack-$(_USERID))
	@[ -d $(_BUILDDIR) ] || mkdir $(_BUILDDIR)


.PHONY: set_environment
set_environment: set_environment_local set_environment_aws
	@# target: set_environment
	@#   wrapper to set local and  aws environment via dependency rules
	@#   note: keep three separate targets to ensure ordering is enforced


.PHONY: package
package: set_environment
	@# target: package
	@# 	package CloudFormation (nested) Stacks and Lambdas
	aws cloudformation package \
		--profile $(_AWS_PROFILE) \
		--template-file $(_TEMPLATE) \
		--s3-bucket $(ArtifactBucket) \
		--s3-prefix $(_DEPLOYSTACK) \
		--output-template-file $(_BUILDDIR)/template.yaml


.PHONY: pre_process
pre_process: set_environment read_configuration
	@# target: pre_process
	@#	calls ./pre_process.sh
	@# parameters.ini is sourced from _BUILDDIR as it may be auto-generated
	@# only copy when source is an update
	[ ! -s "$(_TEMPLATE_ROOT)"/parameters.ini ] || \
		(cp -u "$(_TEMPLATE_ROOT)"/parameters.ini "$(_BUILDDIR)/parameters.ini")
	@# run pre_process.sh if it exist
	[ ! -s "$(_TEMPLATE_ROOT)/pre_process.sh" ] || \
	( \
		cd "$(_TEMPLATE_ROOT)" && \
        export AWS_PROFILE=$(_AWS_PROFILE); \
        export CONFIGURATION_BUCKET=$(ArtifactBucket); \
        export STACKNAME=$(_DEPLOYSTACK); \
        export BUILDDIR=$(_WORKDIR)/$(_BUILDDIR); \
		echo "RUNSCRIPT:$(_TEMPLATE_ROOT)/pre_process.sh"; \
		bash ./pre_process.sh; \
		exit_code="$$?"; \
		echo "FINISHED:$(_TEMPLATE_ROOT)/pre_process.sh (exit=$${exit_code})"; \
		exit $${exit_code}; \
	)


.PHONY: post_process
post_process: set_environment read_configuration
	@# target: post_process
	@#	exports Stack Outputs to environment
	@#	calls ./post_process.sh
	$(eval _STACK_OUTPUTS = $(shell \
		aws cloudformation describe-stacks \
			--profile $(_AWS_PROFILE) \
			--stack-name $(_DEPLOYSTACK) \
			--query 'Stacks[0].Outputs[].{OutputKey:OutputKey,OutputValue:OutputValue}' \
			--output text 2>/dev/null |awk -F '\t' '{print $$1"="$$2}' |sed 's/^None=$$//g'; \
	))
	[ ! -s "$(_TEMPLATE_ROOT)/post_process.sh" ] || \
	( \
		cd "$(_TEMPLATE_ROOT)" && \
        export AWS_PROFILE=$(_AWS_PROFILE); \
        export CONFIGURATION_BUCKET=$(ArtifactBucket); \
        export STACKNAME=$(_DEPLOYSTACK); \
        export BUILDDIR=$(_WORKDIR)/$(_BUILDDIR); \
		[ ! -z "$(_STACK_OUTPUTS)" ] && export $(_STACK_OUTPUTS); \
		echo "RUNSCRIPT:$(_TEMPLATE_ROOT)/post_process.sh"; \
		bash ./post_process.sh; \
		exit_code="$$?"; \
		echo "FINISHED:$(_TEMPLATE_ROOT)/post_process.sh (exit=$${exit_code})"; \
		exit $${exit_code}; \
	)


.PHONY: init_configuration
init_configuration: set_environment
	@# target: init_configuration
	@#	deploy Configuration Stack if no matching version is found,
	@#	determined by output check on ArtifactBucket.
	@#	init is skipped with noconfig=true variable set when called via make clean
ifneq ($(noconfig),true)
	$(cfn-env) \
	create_configuration_template || exit 1; \
	output=$$(configstack_output $(_CONFIGSTACK) "ArtifactBucket" || true); \
	[ ! -z $${output} ] || \
		aws cloudformation deploy \
			--profile $(_AWS_PROFILE) \
			--no-fail-on-empty-changeset \
			--template-file .build/configstack.yaml \
			--capabilities CAPABILITY_NAMED_IAM \
			--stack-name $(_CONFIGSTACK) \
			--parameter-overrides \
				RoleName=ConfigStackDeployRole-$(_USERID)
endif


.PHONY: read_configuration
read_configuration: init_configuration
	@# target: read_configuration
	@#	retrieve configuration vars ArtifactBucket and IAMServiceRole,
	@#	set vars in Makefile environment so other targets can access them
	$(eval ArtifactBucket = $(shell \
		$(cfn-env) printf $$(configstack_output $(_CONFIGSTACK) ArtifactBucket) \
	))
	$(if $(ArtifactBucket),,$(error ConfigStack missing parameter: ArtifactBucket))
	$(eval IAMServiceRole = $(shell \
		$(cfn-env) printf $$(configstack_output $(_CONFIGSTACK) IAMServiceRole) \
	))
	$(if $(IAMServiceRole),,$(error ConfigStack missing parameter: IAMServiceRole))


.PHONY: delete
delete: set_environment read_configuration
	@# target=delete:
	@#	get IAMServiceRole (supplied by Configuration Stack) and delete stack
	@#	if no Configuration Stack exists, one is created (init_configuration)
	@$(cfn-env) delete_stack $(_DEPLOYSTACK) $(IAMServiceRole)
	@echo Stack is Deleted: $(_DEPLOYSTACK)


.PHONY: delete_full
delete_full: delete
	@# target=delete_full
	@#	calls delete target via dependency
	@#  removes Configuration Stack and .build dir
	@if [ -z "$(ArtifactBucket)" ] && [ -z "$(IAMServiceRole)" ];then \
		echo "Nothing to erase"; \
	else \
		$(cfn-env) delete_stack_configuration "$(_CONFIGSTACK)"; \
		echo Stack and Configuration are Deleted: $(_DEPLOYSTACK); \
	fi


.PHONY: clean
clean:
	@# target=clean:
	@#  delete local ./.build directory
	@#	add stack=$${DIRECTORY} to also delete stack data
	# Note that configstack cant be deleted as long as there is one stack
#ifneq ($(_TEMPLATE),)
	@# if either _TEMPLATE or _GIT_REPOSITORY is set, do full stack delete
ifneq ($(filter %,$(_TEMPLATE) $(_GIT_REPOSITORY)),)
	make -f "$(lastword $(MAKEFILE_LIST))" delete_full \
		git="$(_GIT_REPOSITORY)" \
		template="$(_TEMPLATE)" \
		noconfig="true"
endif
	rm -rf ./.build


.PHONY: pre
pre: pre_process
	@# target=pre:
	@#	calls target pre_process
	@echo PreProcess ran succesfully: $(_TEMPLATE_ROOT)/pre_process.sh


.PHONY: post
post: post_process
	@# target=post:
	@#	calls target post_process
	@echo PostProcess ran succesfully: $(_TEMPLATE_ROOT)/post_process.sh
	@[ -z "$(_STACK_OUTPUTS)" ] || \
	( \
		echo -e "\e[92mStackOutputs":; \
		for output in $(_STACK_OUTPUTS);do \
			echo -e "\e[37m$$(printf $${output} |sed 's/=/\ =\ /g')"; \
		done \
	)

.PHONY: list
list: set_environment_aws
	@# target=list
	@# iterate over list with describe
	aws cloudformation list-stacks \
		--profile $(_AWS_PROFILE) \
		--no-paginate --query \
			'StackSummaries[?StackStatus!=`DELETE_COMPLETE`] | [?ParentId==`null`] | [?starts_with(StackName,`$(_USERID)-`)].StackName' \
		 --output text


.PHONY: build
build: set_workdir
ifeq ($(mode),write)
ifeq ($(path),)
	@echo 'path=$${PATH} is mandatory for build target'
else
	@echo 'Create path=$(path)'
	$(git-env) git_merge_include "$(path)"
endif
else
	@echo 'SAFETYCHECK: to prevent running this by accident, append mode=write'
endif


.PHONY: whoami
whoami:
	@# target=whoami:
	@#   verify AWS profile used by this Makefile
	aws sts get-caller-identity --profile "$(_AWS_PROFILE)"


.PHONY: version
version:
	@# target=version:
	@echo Version=$(VERSION)


.PHONY: license
license: version
	@# target=license:
	@echo License notice:
	@cat <<< "$${LICENSE}"


.PHONY: check
check: set_environment
	@echo workdir=$(_WORKDIR)
	@echo templateroot=$(_TEMPLATE_ROOT)
	@echo configstack=$(_CONFIGSTACK)
	@echo deploystack=$(_DEPLOYSTACK)
	@echo template=$(_TEMPLATE)
	@echo TODO List:
	@echo "- (continuous) -- refactor and improve doc-strings"
	@echo "- make clean should delete all related stacks, determined by: make list"
	@echo "- clean s3 config folder as part of stack delete"
	@echo "- if stack is protected, skip deletion (vs. giving an error now)"
	@echo "- test, with cfn-python-lint"
	@echo "- check if tools exist on host, e.g. git and cfn-python-lint -- or error"
	$(git-env) error_test "$(_TEMPLATE_ROOT)" "$(_WORKDIR)"


export CFN_FUNCTIONS
export GIT_FUNCTIONS
export GIT_IGNORE
export LICENSE


define cfn-env
	source .build/cfn_functions.sh; \
	export AWS_PROFILE=$(_AWS_PROFILE); \
	exit_on_error
endef

define git-env
	source .build/git_functions.sh; \
	exit_on_error
endef


define CFN_FUNCTIONS
# repetively called shell functions are added here, contents are exported
# to environment and written to file, and sourced via cfn-env.
#
# vars set via Makefile: _AWS_PROFILE, _STACKNAME_CONFIG, _STACKNAME,
#  _REPOSITORY, _WORKDIR

#!/bin/bash

set -o pipefail

function exit_on_error(){
    "$$@"
    local ret=$$?
    if [ ! $$ret -eq 0 ];then
        >&2 echo "ERROR: Command [ $$@ ] returned $$ret"
        exit $$ret
    fi  
}

function configstack_output(){
    # retrieve output value by passing name of OutputKey as input argument
    # input: {STACKNAME} {KEY}
    aws cloudformation describe-stacks \
        --profile $${AWS_PROFILE} \
        --stack-name "$${1}" \
        --query 'Stacks[0].Outputs[?OutputKey==`'$${2}'`].OutputValue' \
        --output text 2>/dev/null || return $$?
}

function stack_status(){
    # retrieve status of stack by passing unique stack-name as input argument
    # input: {STACKNAME}
    aws cloudformation list-stacks \
        --profile $${AWS_PROFILE} \
        --no-paginate \
        --query 'StackSummaries[?StackName==`'$${1}'`].[StackStatus][0]' \
        --output text
    return $$?
}

function stack_delete_waiter(){
    # configure waiter for stack deletion by passing stack-name as input argument
    # allow up to ~15 minutes for stack deletion
    # if more time is needed, re-check architecture before raising timeout
    local max_rounds=300
    local seconds_per_round=3
    local round=0

    while [ $${round} -lt $${max_rounds} ];do
        local stack_status=$$(stack_status "$${1}")
        echo "WAITER ($${round}/$${max_rounds}):$${1}:$${stack_status}"

        case "$${stack_status}" in
            DELETE_COMPLETE)    return 0;;
            *_FAILED)   return 1;;
            *_IN_PROGRESS|*_COMPLETE);;
            *)  echo "Stack not found"; return 0;;
        esac

        local round=$$[$${round}+1]
        sleep $${seconds_per_round}
    done
    return 1
}

function delete_stack(){
    # delete stack -- role_arn should be passed as input argument
    # input: {STACKNAME} {ROLE_ARN}
    #role_arn="$${1}"

    # return direct ok if application stack is deleted, or not found
    local stack_status=$$(stack_status "$${1}")
    [ -z "$${stack_status}" ] && return 0
    [ "$${stack_status}" == "DELETE_COMPLETE" ] \
    || [ "$${stack_status}" == "None" ] && return 0

    aws cloudformation delete-stack --profile $${AWS_PROFILE} \
        --stack-name "$${1}" \
        --role-arn "$${2}"
    stack_delete_waiter "$${1}"
    return $$?
}

function delete_stack_configuration(){
    # delete stack_configuration and wait -- no input arguments
    # input: {CONFIGSTACK}
    aws cloudformation delete-stack --profile $${AWS_PROFILE} \
        --stack-name "$${1}"
    stack_delete_waiter "$${1}"
    return $$?
}

function derive_stackname(){
    # derive stackname from name of template directory/ repository
    # input: {_TEMPLATE_ROOT} {_GIT_ROOT} {_WORKDIR} {_USERID}
    # use _TEMPLATE_ROOT and strip of leading and trailing slashes
    # select last, or last two (directory-name) columns
    # if result leads to "." (=working directory): use its name
    # dirname "/pg/abc/def/template.yaml" |sed 's/^\///g;s/\/$$//g' | awk -F '/' '{print NF == 1 ? $$NF : $$(NF - 1)"/"$$(NF)}'
    # UserID{8}-Name{0:80}-Branch{29:*}-Commit{8:*}
    # |awk -F '/' '{print NF == 1 ? $$1 : $$(NF - 1)"/"$$(NF)}'
    if [ ! -z "$${2}" ];then
        # if _GIT_ROOT is passed: _TEMPLATE_ROOT is GIT-based
        # strip off commit -- this is (re-)appended to the end of the string in step_1
        # this gives repositories with deep nested templates more human-readable names
        branch_commit="$$(printf "$${2}" |awk -F "--" '{print $$2"--"$$3}')"
        step_0="$$(\
            printf "$${1}" |sed 's/--'$${branch_commit}'$$//g;s/--'$${branch_commit}'\///g'
        )"
    else
        # no adjustments, define commit as empty string
        branch_commit=""
        step_0="$${1}"
    fi

    step_1="$$(\
        printf "$${step_0}" \
        |sed 's/^[\/\.]*//g;s/\/$$//g;s/^\.build\///g' \
        |awk -F '/' '{
            if ( NF == 0 );
            else if ( NF == 1 ) print $$1;
            else if ( NF == 2) print $$(NF - 1)"/"$$(NF);
            else print $$1"_-_"$$(NF - 1)"/"$$(NF);}' \
    )" || return $$?

    if [ -z "$${step_1}" ];then
        step_1=$$(basename "$${3}") || return $$?
    fi
    [ ! -z "$${branch_commit}" ] && step_1="$${step_1:0:80}-$${branch_commit}"
    # remove non [a-zA-Z-] chars and leading/ trailing dash
    # uppercase first char for cosmetics
    step_2=$$(\
        printf "$${step_1}" \
        |sed 's/[^a-zA-Z0-9_]/-/g;s/-\+/-/g;s/^-//g;s/-$$//g;s/_-_/--/g' \
        |awk '{for (i=1;i<=NF;i++) $$i=toupper(substr($$i,1,1)) substr($$i,2)} 1' \
    ) || return $$?
    # if result from step_2 is empty: paste in Unknown-StackName
    # elif char-length >127-9 (127=max naming length on AWS, 9=partial USERID + -)
    #   attain first 109, and last 8 chars (unique commitIDs), separated by double-dash
    #   ensure no leading or trailing dashes remain
    # else no further modifications
    if [ -z "$${step_2}" ];then
        step_3="Unknown-StackName"
    elif [ "$${#step_2}" -gt 119 ];then
        step_3a=$$(\
            printf $${step_2:0:109} \
            |sed s'/^-//g;s/-$$//g' \
        ) || return $$?
        step_3b=$$(\
            printf $${step_2:$$(($${#step_2} - 8)):8} \
            |sed s'/^-//g;s/-$$//g' \
        ) || return $$?
        step_3=$${step_3a}--$${step_3b}
    else
        step_3="$${step_2}"
    fi
    # last 8 chars of USERID + result from step_3
    printf "$${4}-$${step_3}"
    return $$?
}

function create_configuration_template(){

cat << CONFIGURATION_STACK >./.build/configstack.yaml
AWSTemplateFormatVersion: 2010-09-09
Transform: AWS::Serverless-2016-10-31
Description: ConfigurationStack
Parameters:
  RoleName:
    Type: String
Resources:
  Bucket:
    Type: AWS::S3::Bucket
    Properties:
      VersioningConfiguration:
        Status: Enabled
      LifecycleConfiguration:
        Rules:
        - ExpirationInDays: 30
          Status: Disabled
        - NoncurrentVersionExpirationInDays: 7
          Status: Enabled
      BucketEncryption:
        ServerSideEncryptionConfiguration:
        - ServerSideEncryptionByDefault:
            SSEAlgorithm: AES256
  ServiceRoleForCloudFormation:
    Type: AWS::IAM::Role
    Properties:
      RoleName: !Ref RoleName
      AssumeRolePolicyDocument:
        Statement:
        - Effect: Allow
          Principal:
            Service:
            - cloudformation.amazonaws.com
          Action:
          - sts:AssumeRole
      Policies:
      - PolicyName: AdministratorAccess
        PolicyDocument:
          Version: 2012-10-17
          Statement:
          - Effect: Allow
            Action: "*"
            Resource: "*"
  BucketEmptyLambda:
    Type: AWS::Serverless::Function
    Properties:
      Runtime: python3.7
      Handler: index.handler
      Policies:
      - Version: 2012-10-17
        Statement:
          - Effect: Allow
            Action:
            - s3:List*
            - s3:DeleteObject
            - s3:DeleteObjectVersion
            Resource:
            - !Sub \$${Bucket.Arn}
            - !Sub \$${Bucket.Arn}/*
      InlineCode: |
          import boto3
          import cfnresponse
          s3 = boto3.resource('s3')

          def empty_s3(payload):
              bucket = s3.Bucket(payload['BucketName'])
              bucket.object_versions.all().delete()
              return {}

          def handler(event, context):
              try:
                  if event['RequestType'] in ['Create', 'Update']:
                      # do nothing
                      cfnresponse.send(event, context, cfnresponse.SUCCESS,
                                       {}, event['LogicalResourceId'])
                  elif event['RequestType'] in ['Delete']:
                      response = empty_s3(event['ResourceProperties'])
                      cfnresponse.send(event, context, cfnresponse.SUCCESS, response)

              except Exception as e:
                  cfnresponse.send(event, context, "FAILED", {"Message": str(e)})
  CustomCrlBucketEmpty:
    Type: Custom::CrlBucketEmpty
    Properties:
      ServiceToken: !GetAtt BucketEmptyLambda.Arn
      BucketName: !Ref Bucket
Outputs:
  ArtifactBucket:
    Value: !Ref Bucket
  IAMServiceRole:
    Value: !GetAtt ServiceRoleForCloudFormation.Arn
CONFIGURATION_STACK
}

endef

define GIT_FUNCTIONS

#!/bin/bash

set -o pipefail

INCLUDE_FILE='.git_include'

function error(){
    >&2 echo "ERROR: $${1}"
    # >&2 echo "TRACE: $${FUNCNAME[*]}" | awk '{ for(i=NF; i>1; i--) printf("%s:",$$i); print $$1;}'
    return_code="$${2}"
    [[ ! $${return_code} =~ ^[0-9]+$$ ]] && return_code=1
    return $${return_code}
}

function exit_on_error(){
    "$$@"
    local ret=$$?
    if [ ! $$ret -eq 0 ];then
        >&2 echo "ERROR: Command [ $$@ ] returned $$ret"
        exit $$ret
    fi  
}

function git_destination(){
    # Return clean repository name -- filter out .git and any parameters
    # input: {GIT_REPOSITORY} {WORKDIR}
    local var=$$( 
        basename "$${1}" \
        |sed 's/?.*//g;
              s/\.git$$//g;
              s/[^a-zA-Z0-9_-]//g'
    )
    # TODO: check if still needed
    # if repository is a URL, lowercase
    # urlcheck = sed -n '/^\(http\|ssh\)[s]\?:\/\/\|.*?.*/p'))
    # convert the url part to lowercase to prevent input/ typo mistakes
    # |awk '{print tolower($$0)}' 
    [ ! -z "$${var}" ] \
    && printf "$${var}" \
    || printf $$(basename "$${2}")
    return $$?
}

function git_set_default_user(){
    # set default git user/ email if none exist
    # required to allow automated commits to build repositories
    [ -z "$$(git config user.name)" ] \
        && git config user.name `whoami`
    [ -z "$$(git config user.email)" ] \
         && git config user.email `whoami`@localhost
    # assume success, if fail: git will stop-fail next
    return 0
}

function git_auto_commit(){
    # commit changes automatically
    git_set_default_user
    git add . \
    &&  (
            git diff-index --quiet HEAD 2>/dev/null \
            || git commit -am "__auto_commit__:$$(date +%s)"
        )
    return $$?
}

function git_parameter(){
    # extract parameter value from URL
    local uri_str="$${1}"
    local parameter_name="$${2}"
    # pre-set default value
    local parameter_value="$${3}"

    read parameter_pair <<< $$(
        sed -n 's/.*\('$${parameter_name}'=[A-Za-z0-9-]*\).*/\1/p' \
        <<< "$${uri_str##*\?}"
    ) || return $$?

    [ ! -z "$${parameter_pair}" ] &&
        local parameter_value=$${parameter_pair#*=}

    printf "$${parameter_value}"
    return $$?
}

function git_namestring(){
    # Return a string formatted as RepoName--Branch--Commit
    local repository="$${1}"
    local workdir="$${2}"

    local rname="$$(git_destination "$${repository}" "$${workdir}")" || return $$?
    local branch="$$(git_parameter "$${repository}" branch master)" || return $$?
    local commit="$$(git_parameter "$${repository}" commit latest)" || return $$?
    if [ "$${commit}" = 'latest' ];then
        local heads=$$(git ls-remote "$${repository%\?*}" refs/heads/"$${branch}")
        local commit=$$(printf "$${heads}" |awk '{print $$1}')
        if [ -z "$${commit}" ];then
            >&2 echo "ERROR: cant find branch \"$${branch}\" on \"$${repository%\?*}\""
            return 1
        fi
    fi
    printf "$${rname}--$${branch}--$${commit}"
    return $$?
}


function pull_from_git(){
    # pull repository and checkout to specified branch tag/commit
    local origin="$${1}"
    local workdir="$${2}"

    local branch=$$(git_parameter "$${origin}" branch master) || return $$?
    local target=.build/"$$(git_namestring "$${origin}" "$${workdir}")" || return $$?

    # if repository exists local: fetch, else: clone
    if [ -e "$${target}"/.git ];then
        (
            cd "$${target}" \
            && git fetch origin \
            && git reset --hard origin/master
        ) || return $$?
    else
        git clone -b "$${branch}" "$${origin%\?*}" "$${target}" \
        || return $$?
    fi

    # if _commit: checkout commit position, else: checkout latest
    local commit=$$(git_parameter "$${origin}" commit) || return $$?
    if [ ! -z "$${commit}" ] && [ "$${commit}" != 'latest' ];then
        (
            cd "$${target}" \
            && git checkout -B $${branch} $${commit} \
            || return $$?
        )
    else
        (
            cd "$${target}" \
                && git checkout -B $${branch} \
                && git pull \
                || return $$?
        )
    fi
    return $$?
}

function git_update_remote_config(){
    local remote="$${1}"
    local repository="$${2}"
    local exist=$$(
        git remote |sed -n 's/\(^'$${remote}'$$\)/\1/p'
    ) || return $$?
    # remove existing version if exist
    if [ ! -z "$${exist}" ];then
        git remote rm "$${remote}" || return $$?
    fi
    git remote add "$${remote}" "$${repository}"
    return $$?
}

function git_delete_branch_if_exist(){
    local branchname="$${1}"
    if git show-ref --verify --quiet refs/heads/"$${branchname}";then
        git branch -D "$${branchname}" || return $$?
    fi
    return 0
}

function git_set_ignore(){
    [ -d .build ] || mkdir .build || return 1
    cat << IGNORE_FILE_BUILD >.build/.gitignore 
# ignore everything under build
# .build/* should only contain generated data
# this file is auto-generated by Makefile
*
IGNORE_FILE_BUILD
    return $$?
}

function init_build_repo(){
    # create a brand new repo
    local directory="$${1}"
    [ ! -d "$${directory}"/.git ] \
    || error "$${directory}/.git ALREADY EXISTS" $$? \
    || return $$?

    mkdir -p "$${directory}" \
    || error "FAILED TO CREATE: $${directory}" $$? \
    || return $$?

    cd "$${directory}" \
    && git init -q \
    || return $$?

    if [ ! -z "$${2}" ] && [ "$$2" = 'commit' ];then
        git_set_ignore \
        && git add -f .build/.gitignore >/dev/null \
        && git commit -q -am '__auto__Makefile:init__' \
        && git add . >/dev/null \
        && git commit -q -am '__auto__Makefile:xxxx__' \
        || return $$?
    fi
    printf "$${directory}"
    return $$?
}
    
    #&& git add . \

function git_extract_path(){
    # extract path-contents from one repository to another
    # pathmap='$${origin_path}:$${target_path}'
    local pathmap="$${1}"
    local origin_repo="$${2}"
    local target_repo="$${3}"

    # split pathmap in origin- and new path 
    local origin_path="$${pathmap%:*}"
    local target_path="$${pathmap##*:}"

    if [ -z "$${origin_path}" ] || [ -z "$${target_path}" ];then
        error "FAILED READING PATHMAP \"$${pathmap}\""
        return 1
    fi

    local workdir="$$(pwd)"
    pull_from_git "$${origin_repo}" "$${workdir}" || return $$?

    # ensure source repository is in original state
    local source_name=$$(git_namestring "$${origin_repo}" "$${workdir}")
    local source_repo="$${workdir}"/.build/"$${source_name}"
    local source_branch=$$(git_parameter "$${source_repo}" branch master) || return $$?

    # filter origin_path to a new (path-)branch in source repository
    (
        # ensure we are in the source_repo
        cd "$${source_repo}" || return $$?

        # verify commit. Var is also re-used later as unique var used to put files in
        branchid="$$(
            git log -n1 --pretty=format:%h -- "$${origin_path}"
        )__$${target_path//\//-}"
        [ -z "$${branchid}" ] && continue

        # Create a clean orphan branch
        git_delete_branch_if_exist "$${branchid}" \
        && git checkout --orphan "$${branchid}" \
        && git rm -qfr --cached --ignore-unmatch . \
        && git clean -qfd \
        || return $$?

        # Merge $${origin_path} into orphan branch
        git checkout "$${source_branch}" -- "$${origin_path}"/ \
        || return $$?

        # ensure "$${target_path} is the only remaining directory
        # complicated directory dance to make collission chance neglible
        tmpdir=."$${branchid}"
        mv "$${origin_path}" "$${tmpdir}" \
        && git rm -qfr --cached --ignore-unmatch . \
        && git clean -qf * \
        && mkdir -p "$$(dirname "$${target_path}")" \
        && mv "$${tmpdir}" "$${target_path}" \
        && git_auto_commit || return $$?
    ) || return $$?

    # merge (path-)branch to build_repo
    (
        # merge branch 
        cd "$${target_repo}" \
        && git_update_remote_config "$${source_name}" "$${source_repo}" \
        && git pull --depth 1 "$${source_name}" "$${branchid}" \
             --allow-unrelated-histories --no-edit -X theirs \
        || return $$?

        git remote rm "$${source_name}"
    ) || return $$?
    return 0
}


function git_merge_include(){
    # process .git_include file and merge referenced repository-contents
    path="$${1}"

    if [ ! -z "$${path}" ];then
        cd ./"$${path}" || error "CANT CHANGE TO PATH \"$${path}\"" $$? || return $$?
    fi

    # set GIT user if none is set. This is needed to enable commit functionality
    # in non-developer environments (e.g. deployment pipelines)
    git_set_default_user

    if [ ! -d .git ];then
        init_build_repo '.' 'commit' \
        || error 'FAILED TO INITIALISE GIT REPO' $$? || return $$?
    fi

    # retrieve section_names ([...]) from file
    local section_names=$$(
        sed 's/^\[//g;s/\]//g' <<< \
            $$(sed -n 's/\(^\[[-A-Za-z0-9_.:/@?=&]*\]\)$$/\1/p' "$${INCLUDE_FILE}")
    ) || error 'FAILED READING SECTION NAMES' $$? || return $$?

    # escape newlines (idea by: https://stackoverflow.com/questions/1251999)
    local contents=$$(
        sed -e ':a' -e 'N' -e '$$!ba' -e 's/\n/\\n/g' "$${INCLUDE_FILE}"
    ) || error 'FAILED READING CONTENTS' $$? || return $$?

    # get clean working repository to initially store the pulls
    local build_repo="$$(pwd)"/"$$(
        init_build_repo ".build/temp-git-$$(($$(date +%s%N)/1000000))"
    )" || error 'FAILED CREATING BUILD_REPO' $$? || return $$?

    # iterate over sections
    for name in $${section_names};do
    (
        # extract section block required for this iteration
        section=$$(
            sed 's/.*\(\['$${name}'\][^[]*\).*/\1/;
                 s/\\n/\n/g' <<< "$${contents}"
        ) || error "FAILED TO EXTRACT SECTION \"$${name}\"" $$? || return $$?

        # extract repository=value
        read repository_kv <<< $$(
            sed -n 's/\(^repository=[-A-Za-z0-9:/.@?=&]*\)$$/\1/p' <<< "$${section}"
        )
        if [ ! $$? -eq 0 ] || [ -z "$${repository_kv#*=}" ];then
            error "MISSING repository=[-A-Za-z0-9:/.@?=&]* IN \"$${name}\""
            return 1
        fi

        # extract pathlist=value
          # value: comma separated list of '$${source_path}:$${new_path}' pairs
          # chars [-A-Za-z0-9_/.@=+] are safe to use for path-names
        read pathlist_kv <<< $$(
            sed -n 's/\(^pathlist=[-A-Za-z0-9:_/.@=+,]*\)$$/\1/p' <<< "$${section}"
        )
        if [ ! $$? -eq 0 ] || [ -z "$${pathlist_kv#*=}" ];then
            error "MISSING pathlist=[-A-Za-z0-9:_/.@=+,]* IN \"$${name}\""
            return 1
        fi

        # for each path in list, extract the contents to build_repo
        # merge strategy is "-X theirs" -- i.e. each next path supersedes the former
        pathlist_str="$${pathlist_kv#*=}"
        for pathmap in $${pathlist_str//,/ };do
            git_extract_path \
                "$${pathmap}" "$${repository_kv#*=}" "$${build_repo}" \
            || error "FAILED TO PROCESS \"$${pathmap}\"" $$? || return $$?
        done
    ) || return $$?
    done

    # Merge the contents of build_repo to working repository (/branch)
    # merge strate is "-X ours" -- i.e. working repository supersedes build_repo
    git_update_remote_config "final-merge" "$${build_repo}" || return $$?
    git pull --depth 1 "final-merge" master --allow-unrelated-histories \
        --no-edit -X ours || return $$?

    # fetch only
    # git fetch --depth 1 --no-tags --no-recurse-submodules final-merge master:my-new-branch 
    git remote rm final-merge || return $$?

    # if .git is an auto-created sibling-git (i.e. temporary): clean it up
    # determine by:
    # - first_commit signature
    # - is_git-query one directory up in the hierarchy (redundant safety-check)
    if [ -d .git ];then
        first_commit="$$(
            git log --reverse --pretty=oneline 2>/dev/null \
            |sed -n 's/.*\(__auto__Makefile:init__\)$$/\1/p'
        )" || return $$?

        [ ! -z "$${first_commit}" ] \
        && [ "$${first_commit}" = '__auto__Makefile:init__' ] \
        && (
            cd ../ \
            && git rev-parse --is-inside-work-tree >/dev/null 2>&1;
            return $$?
        ) && rm -rf .git
    fi
    # cleanup all remaining build artifacts
    [ -d .build ] && rm -rf .build
    return 0
}

endef

define GIT_IGNORE
    cat << IGNORE_FILE_BUILD >.build/.gitignore 
# ignore everything under build
# .build/* should only contain generated data
# this file is auto-generated by Makefile
*
IGNORE_FILE_BUILD
endef

define LICENSE
Copyright (c) 2020 Anthony Potappel - LINKIT, The Netherlands.
SPDX-License-Identifier: MIT

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
endef

.PHONY: show_help
show_help:
	@echo '$(NAME)'
	@echo '  Makefile to Deploy, Update or Delete Stacks on AWS via CloudFormation'
	@echo 'Version: $(VERSION) ($(DATE))'
	@echo 'Usage:'
	@echo '  command: make [TARGET] [CONFIGURATION]'
	@echo ''
	@echo 'Targets:'
	@echo '  deploy         Deploy or Update a Stack (includes Pre- and PostProcess)'
	@echo '  delete         Delete a Stack (excludes related configuration data)'
	@echo '  clean          Delete local ./.build directory'. Add stacks=destroy to
	@echo '                 destroy all (un-protected) Stacks starting with UserId-'
	@echo '                 wipe Stack related configuration data'
	@echo '  pre            Run $${TEMPLATE_ROOT}/pre_process.sh if file exists'
	@echo '  post           Run $${TEMPLATE_ROOT}/post_process.sh if file exists'
	@echo '  help           Show this help'
	@echo ''
	@echo 'Configuration:'
	@echo '  profile=$${AWS_PROFILE}     Set AWS CLI profile (default: "default", '
	@echo '                               check available profiles: "aws configure list")'
	@echo '  template=$${_TEMPLATE}      Name of CloudFormation rootstack template,'
	@echo '                               (default: "./template.yaml")'
	@echo '  git=$${GITURL || GITDIR}    Optionally retrieve stack from Git'
	@echo '  stackname=$${STACKNAME}     Set STACKNAME manually (not recommended)'
	@echo ''
	@echo 'Developer Targets:'
	@echo '  build path=$${PATH}}     Build CloudFormation Configuration Stack'
	@# echo 'noconfig=true            Skips building Configuration Stack'
	@# echo '                         option hidden, used via "make clean stack={}"'
