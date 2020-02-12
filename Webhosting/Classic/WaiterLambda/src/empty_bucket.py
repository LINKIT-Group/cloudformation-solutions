# Copyright (c) 2020 Anthony Potappel - LINKIT, The Netherlands.
# SPDX-License-Identifier: MIT

import json
import boto3
import logging
import urllib.request

logger = logging.getLogger()
logger.setLevel(logging.INFO)


s3 = boto3.resource('s3')


def empty_s3(payload):
    """Empty all files in Bucket"""
    bucket = s3.Bucket(payload['BucketName'])
    bucket.object_versions.all().delete()
    return {}


def handler(event, context):
    """Called by Lambda -- only act on Delete"""
    try:
        if event['RequestType'] in ['Delete']:
            send_cfnresponse(
                event, context, 'SUCCESS', empty_s3(event['ResourceProperties'])
            )
        else:
            send_cfnresponse(
                event, context, 'SUCCESS', {}, event['LogicalResourceId']
            )
    except Exception as e:
        send_cfnresponse(event, context, 'FAILED', {'Message': str(e)})


def send_cfnresponse(
        event, context, responseStatus, response_data,
        physicalResourceId=None, noEcho=False
    ):
    responseUrl = event['ResponseURL']

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
