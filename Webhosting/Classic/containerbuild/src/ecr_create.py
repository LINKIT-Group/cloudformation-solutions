# Copyright (c) 2020 Anthony Potappel - LINKIT, The Netherlands.
# SPDX-License-Identifier: MIT

import logging
import json
import boto3
import urllib.request

logger = logging.getLogger()
logger.setLevel(logging.INFO)


ecr_client = boto3.client("ecr")


def repository_exists():
    """Check if ECR repository exists"""
    """TODO: add pagination"""
    response = ecr_client.describe_repositories(maxResults=500)
    return [repo['repositoryName'] for repo in response['repositories']]


def ecr_create(name):
    return ecr_client.create_repository(
        repositoryName=name,
        imageTagMutability='MUTABLE'
    )


def ecr_delete(name):
    return ecr_client.delete_repository(
        repositoryName=name,
        force=True
    )


def repository(request_type, payload):
    """Create or Delete ECR repository"""
    repository_list = payload['RepositoryList'].split(',')

    if not repository_list:
        return {}

    if request_type == 'Delete':
        try:
            if payload['Retain'].lower() == "true":
                return {}
        except:
            pass

        exists = repository_exists()
        for name in repository_list:
            if name in exists:
                ecr_delete(name)
    else:
        exists = repository_exists()
        for name in repository_list:
            if name not in exists:
                ecr_create(name)

    return {f"{request_type}d": payload['RepositoryList']}


def handler(event, context):
    """Called by Lambda"""
    try:
        request_type = event['RequestType']
        if request_type not in ['Create', 'Update', 'Delete']:
            raise ValueError(f"RequestType invalid:{str(request_type)}")
        send(event,
             context,
             'SUCCESS',
             repository(request_type, event['ResourceProperties']),
             event['LogicalResourceId']
        )
    except Exception as e:
        send(event, context, "FAILED", {"Message": str(e)})


def send(event, context, responseStatus, response_data, physicalResourceId=None, noEcho=False):
    responseUrl = event['ResponseURL']
    logger.info(responseUrl)

    response_body = {
        "Status" : responseStatus,
        "Reason": f"See the details in CloudWatch Log Stream: {context.log_stream_name}",
        "PhysicalResourceId": physicalResourceId or context.log_stream_name,
        "StackId": event['StackId'],
        "RequestId": event['RequestId'],
        "LogicalResourceId": event['LogicalResourceId'],
        "NoEcho": noEcho,
        "Data": response_data
    }

    json_responseBody = json.dumps(response_body)
    logger.info("Response body:\n" + json_responseBody)

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
            logger.info(f"Status code: {str(response.getcode())}")
    except Exception as e:
        logger.info(f"send(..) failed executing requests.put(..): {str(e)}")

