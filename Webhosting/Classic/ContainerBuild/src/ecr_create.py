# Copyright (c) 2020 Anthony Potappel - LINKIT, The Netherlands.
# SPDX-License-Identifier: MIT

import re
import json
import boto3
import json
import logging
import urllib.request

logger = logging.getLogger()
logger.setLevel(logging.INFO)


ecr_client = boto3.client("ecr")


def trim_alphanum(name, length=100):
    """Replace non alphanum charss with '-',
    remove leading, trailing and double '-' chars, trim length"""
    return re.sub(
        '^-|-$', '', re.sub('[-]+', '-', re.sub('[^-a-zA-Z0-9]', '-', name[0:length]))
    )

trim_alphanum_list = lambda l, s: [trim_alphanum(sub, length=s) for sub in l]


def repository_exists():
    """Check if ECR repository exists"""
    """TODO: add pagination"""
    response = ecr_client.describe_repositories(maxResults=500)
    return [repo['repositoryName'] for repo in response['repositories']]


def create_repository(name):
    return ecr_client.create_repository(
        repositoryName=name,
        imageTagMutability='MUTABLE'
    )


def delete_repository(name):
    return ecr_client.delete_repository(
        repositoryName=name,
        force=True
    )


def update_repository_names(environment_name, repolist_str):
    """If environment_name: add it to each name in repolist
    Ensure environment_name and repolist names match ECR naming spec"""
    # repolist_str is commadelimited list of repositories
    # correct name for each part in repository path
    if not repolist_str:
        return []

    ecr_name_limit = 255 - len(environment_name) - 1

    path_error = ''.join([
        ' Input path(s) must be [-A-Za-z0-9/]',
        ', start with a letter',
        ', invalid patterns: [\'--\', \'-/\', \'/-\']',
        f', name cant exceed 255 chars.'
    ])

    repolist = []
    for path in repolist_str.split(','):
        # note input repolist_str can be uppercase
        # ecr path will be lowercased
        ecr_path = path.lower()
        if not re.match('^[a-z]', ecr_path[0]) or len(ecr_path) > ecr_name_limit:
            raise ValueError(''.join([[f'Path invalid: {environment_name}/{path}.'] + path_error]))

        path_update = '/'.join(trim_alphanum_list(ecr_path.split('/'), ecr_name_limit))

        if ecr_path != path_update:
            # path altered, which means it did not match required pattern
            raise ValueError(''.join([[f'Path invalid: {environment_name}/{path}.'] + path_error]))
        repolist.append(ecr_path)

    return repolist


def repository(request_type, payload):
    """Create or Delete ECR repository"""
    repolist_str = payload.get('RepositoryPathList', '')
    environment_name = payload.get('EnvironmentName', 'Dev')
    if environment_name != trim_alphanum(environment_name, length=127):
        raise ValueError('.'.join([
            'EnvironmentName must match [-A-Za-z0-9]',
            ', start with a letter, repeating hyphens not allowed'
        ]))

    repolist = update_repository_names(environment_name, repolist_str)

    if not repolist:
        return {
            'EnvironmentName': environment_name,
            'RepositoryPathList': '',
            'EcrDelete': '',
            'EcrCreate': ''
        }

    ecr_create_list = []
    ecr_delete_list = []
    if request_type == 'Delete':
        try:
            if payload['Retain'].lower() == 'true':
                return {
                    'EnvironmentName': environment_name,
                    'RepositoryPathList': ','.join(repolist),
                    'EcrDelete': '',
                    'EcrCreate': ''
                }
        except:
            pass

        exists = repository_exists()

        for reponame in repolist:
            fullname = '/'.join([environment_name, reponame]).lower()
            if fullname in exists:
                delete_repository(fullname)
            ecr_delete_list.append(fullname)
    else:
        exists = repository_exists()
        for reponame in repolist:
            fullname = '/'.join([environment_name, reponame]).lower()
            if fullname not in exists:
                create_repository(fullname)
            ecr_create_list.append(fullname)

    return {
        'EnvironmentName': environment_name,
        'RepositoryPathList': ','.join(repolist),
        'EcrDelete': ','.join(ecr_delete_list),
        'EcrCreate': ','.join(ecr_create_list)
    }


def handler(event, context):
    """Called by Lambda"""
    try:
        request_type = event['RequestType']
        if request_type not in ['Create', 'Update', 'Delete']:
            raise ValueError(f'RequestType invalid:{str(request_type)}')
        send(event,
             context,
             'SUCCESS',
             repository(request_type, event['ResourceProperties']),
             event['LogicalResourceId']
        )
    except Exception as e:
        send(event, context, 'FAILED', {'Message': str(e)})


def send(event, context, responseStatus, response_data, physicalResourceId=None, noEcho=False):
    responseUrl = event['ResponseURL']
    logger.info(responseUrl)

    response_body = {
        'Status' : responseStatus,
        'Reason': f'See the details in CloudWatch Log Stream: {context.log_stream_name}',
        'PhysicalResourceId': physicalResourceId or context.log_stream_name,
        'StackId': event['StackId'],
        'RequestId': event['RequestId'],
        'LogicalResourceId': event['LogicalResourceId'],
        'NoEcho': noEcho,
        'Data': response_data
    }

    json_responseBody = json.dumps(response_body)
    logger.info('Response body:\n' + json_responseBody)

    headers = {
        'content-type': '',
        'content-length': str(len(json_responseBody))
    }

    try:
        req = urllib.request.Request(
            responseUrl,
            data=json_responseBody.encode(),
            headers=headers,
            method='PUT'
        )
        with urllib.request.urlopen(req) as response:
            logger.info(f'Status code: {str(response.getcode())}')
    except Exception as e:
        logger.info(f'send(..) failed executing requests.put(..): {str(e)}')
