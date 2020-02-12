# Copyright (c) 2020 Anthony Potappel - LINKIT, The Netherlands.
# SPDX-License-Identifier: MIT


import logging
import json
import boto3
import urllib.request

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ssm_client = boto3.client('ssm')


def ssm_update_parameter(name, value, tags=[]):
    ssm_client.put_parameter(
        Name=name,
        Value=value,
        Type='String',
        Overwrite=True,
        Tags=tags,
        Tier='Standard'
    )
    return {'ParameterName': name}


def parameter_exists(name):
    """Check if Parameter exists"""
    response = ssm_client.describe_parameters(
        Filters=[
            {'Key': 'Type', 'Values': ['String']},
            {'Key': 'Name', 'Values': [name]}
        ]
    )

    if response.get('Parameters', []):
        return True

    # no match
    return False


def create_parameter(payload, request):
    """Create new SSM Parameter if not yet exists"""
    return ssm_update_parameter(payload['ParameterName'], payload['ParameterValue'])


def delete_parameter(payload):
    """Remove SSM Parameter"""
    if parameter_exists(payload['ParameterName']) is False:
        # nothing needs to be done
        return {}

    ssm_client.delete_parameter(Name=payload['ParameterName'])
    return {}


def handler(event, context):
    """Called by Lambda"""
    try:
        if event['RequestType'] in ['Delete']:
            send(
                event,
                context,
                'SUCCESS',
                delete_parameter(event['ResourceProperties']),
                event['LogicalResourceId']
            )
        elif event['RequestType'] in ['Create', 'Update']:
            send(
                event,
                context,
                'SUCCESS',
                create_parameter(event['ResourceProperties'], event['RequestType']),
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
