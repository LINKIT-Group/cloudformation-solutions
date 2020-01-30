#!/bin/bash

set -o pipefail

function exit_on_error(){
    "$@"
    local ret=$?
    if [ ! $ret -eq 0 ];then
        >&2 echo "ERROR: Command [ $@ ] returned $ret"
        exit $ret
    fi  
}

function configstack_output(){
    # retrieve output value by passing name of OutputKey as input argument
    # input: {STACKNAME} {KEY}
    aws cloudformation describe-stacks \
        --profile $(_AWS_PROFILE) \
        --stack-name "${1}" \
        --query 'Stacks[0].Outputs[?OutputKey==`'${2}'`].OutputValue' \
        --output text 2>/dev/null || return $?
}

function stack_status(){
    # retrieve status of stack by passing unique stack-name as input argument
    # input: {STACKNAME}
    aws cloudformation list-stacks \
        --profile $(_AWS_PROFILE) \
        --no-paginate \
        --query 'StackSummaries[?StackName==`'${1}'`].[StackStatus][0]' \
        --output text
    return $?
}

function stack_delete_waiter(){
    # configure waiter for stack deletion by passing stack-name as input argument
    # allow up to ~15 minutes for stack deletion
    # if more time is needed, re-check architecture before raising timeout
    local max_rounds=300
    local seconds_per_round=3
    local round=0

    while [ ${round} -lt ${max_rounds} ];do
        local stack_status=$(stack_status "${1}")
        echo "WAITER (${round}/${max_rounds}):${1}:${stack_status}"

        case "${stack_status}" in
            DELETE_COMPLETE)    return 0;;
            *_FAILED)   return 1;;
            *_IN_PROGRESS|*_COMPLETE);;
            *)  echo "Stack not found"; return 0;;
        esac

        local round=$[${round}+1]
        sleep ${seconds_per_round}
    done
    return 1
}

function delete_stack(){
    # delete stack -- role_arn should be passed as input argument
    # input: {STACKNAME} {ROLE_ARN}
    #role_arn="${1}"

    # return direct ok if application stack is deleted, or not found
    local stack_status=$(stack_status "${1}")
    [ -z "${stack_status}" ] && return 0
    [ "${stack_status}" == "DELETE_COMPLETE" ] \
    || [ "${stack_status}" == "None" ] && return 0

    aws cloudformation delete-stack --profile $(_AWS_PROFILE) \
        --stack-name "${1}" \
        --role-arn "${2}"
    stack_delete_waiter "${1}"
    return $?
}

function delete_stack_configuration(){
    # delete stack_configuration and wait -- no input arguments
    # input: {CONFIGSTACK}
    aws cloudformation delete-stack --profile $(_AWS_PROFILE) \
        --stack-name "${1}"
    stack_delete_waiter "${1}"
    return $?
}

function derive_stackname(){
    # derive stackname from name of template directory/ repository
    # input: {_TEMPLATE_ROOT} {_GIT_ROOT} {_WORKDIR} {_USERID}
    # use _TEMPLATE_ROOT and strip of leading and trailing slashes
    # select last, or last two (directory-name) columns
    # if result leads to "." (=working directory): use its name
    # dirname "/pg/abc/def/template.yaml" |sed 's/^\///g;s/\/$//g' | awk -F '/' '{print NF == 1 ? $NF : $(NF - 1)"/"$(NF)}'
    # UserID{8}-Name{0:80}-Branch{29:*}-Commit{8:*}
    # |awk -F '/' '{print NF == 1 ? $1 : $(NF - 1)"/"$(NF)}'
    if [ ! -z "${2}" ];then
        # if _GIT_ROOT is passed: _TEMPLATE_ROOT is GIT-based
        # strip off commit -- this is (re-)appended to the end of the string in step_1
        # this gives repositories with deep nested templates more human-readable names
        branch_commit="$(printf "${2}" |awk -F "--" '{print $2"--"$3}')"
        step_0="$(\
            printf "${1}" |sed 's/--'${branch_commit}'$//g;s/--'${branch_commit}'\///g'
        )"
    else
        # no adjustments, define commit as empty string
        branch_commit=""
        step_0="${1}"
    fi

    step_1="$(\
        printf "${step_0}" \
        |sed 's/^[\/\.]*//g;s/\/$//g;s/^\.build\///g' \
        |awk -F '/' '{
            if ( NF == 0 );
            else if ( NF == 1 ) print $1;
            else if ( NF == 2) print $(NF - 1)"/"$(NF);
            else print $1"_-_"$(NF - 1)"/"$(NF);}' \
    )" || return $?

    if [ -z "${step_1}" ];then
        step_1=$(basename "${3}") || return $?
    fi
    [ ! -z "${branch_commit}" ] && step_1="${step_1:0:80}-${branch_commit}"
    # remove non [a-zA-Z-] chars and leading/ trailing dash
    # uppercase first char for cosmetics
    step_2=$(\
        printf "${step_1}" \
        |sed 's/[^a-zA-Z0-9_]/-/g;s/-\+/-/g;s/^-//g;s/-$//g;s/_-_/--/g' \
        |awk '{for (i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2)} 1' \
    ) || return $?
    # if result from step_2 is empty: paste in Unknown-StackName
    # elif char-length >127-9 (127=max naming length on AWS, 9=partial USERID + -)
    #   attain first 109, and last 8 chars (unique commitIDs), separated by double-dash
    #   ensure no leading or trailing dashes remain
    # else no further modifications
    if [ -z "${step_2}" ];then
        step_3="Unknown-StackName"
    elif [ "${#step_2}" -gt 119 ];then
        step_3a=$(\
            printf ${step_2:0:109} \
            |sed s'/^-//g;s/-$//g' \
        ) || return $?
        step_3b=$(\
            printf ${step_2:$((${#step_2} - 8)):8} \
            |sed s'/^-//g;s/-$//g' \
        ) || return $?
        step_3=${step_3a}--${step_3b}
    else
        step_3="${step_2}"
    fi
    # last 8 chars of USERID + result from step_3
    printf "${4}-${step_3}"
    return $?
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
            - !Sub \${Bucket.Arn}
            - !Sub \${Bucket.Arn}/*
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
