# Copyright (c) 2020 Anthony Potappel - LINKIT, The Netherlands.
# SPDX-License-Identifier: MIT

import logging
import json
import uuid
import boto3
import urllib.request

logger = logging.getLogger()
logger.setLevel(logging.INFO)

client = boto3.client('codepipeline')


def resource_status(payload):
    """Return SUCCESS if latest execution status of a Pipeline is 'Succeeded'"""
    executions = client.list_pipeline_executions(
        pipelineName=payload['PipelineName']
    )['pipelineExecutionSummaries']

    try:
        latest_execution_status = executions[0]['status']
        if latest_execution_status == 'Succeeded':
            return {'Status': 'SUCCESS', 'Name': payload['PipelineName']}
    except:
        pass

    return {}


def handler(event, context):
    """Called by eventrule based Lambda"""
    try:
        request_type = event['RequestType']
        if request_type == 'StatusUpdate':
            response = resource_status(event['ResourceProperties'])

            # only send SUCCESS if response contains data
            if response:
                logger.info(json.dumps(
                    {'ResponseStatus': 'SUCCESS', 'ResponseData': response}))
                send_status(event, context, 'SUCCESS', response)
            else:
                logger.info(json.dumps(
                    {'ResponseStatus': 'N/A', 'ResponseData': {}}))
        else:
            raise ValueError(f'RequestType \'{request_type}\' invalid')
    except Exception as e:
        logger.info(f'Unexpected RuntimeError:{str(e)}')
        send_status(event, context, 'FAILED', {'Message': str(e)})


def send_status(event, context, response_status, response_data):
    """Send status by writing back the response to an S3 PreSigned URL"""
    try:
        url = event['ResponseUrlData']['Url']
        formdata = event['ResponseUrlData']['FormData']
        request_id = event['RequestId']
    except:
        # not invoked from an eventrule_lambda
        logger.info('send_status() skipped')
        return

    try:
        """
        Encode formdata and data as multipart/form-data as per AWS spec for S3 PreSigned.
        While this is trivial in Python requests module, the request module is not
        included in the default library set. Using urllib.request allows re-use of this
        function without (pip-)build requirements, which is useful for simple custom resources.
        """

        # Generate random string to pass as boundary
        boundary = str(uuid.uuid4())
    
        # Encode base formdata (fields)
        flatten = lambda l: [item for sublist in l for item in sublist]
        content_items = flatten([
            [f'--{boundary}', f'Content-Disposition: form-data; name="{name}"', '', str(value)]
            for name, value in formdata.items()
        ])
    
        # Append (encoded) response data
        content_items = content_items + [
            f'--{boundary}',
            'Content-Disposition: form-data; name="file";',
            f'Content-Type: application/octet-stream',
            '',
            json.dumps({
                'ResponseStatus': response_status,
                'ResponseData': response_data,
                'RequestId': request_id
            }),
            f'--{boundary}--',
            ''
        ]
    
        # Merge items to a single body, separated by '\r\n'
        response_body = '\r\n'.join(content_items)

        headers = {
            'Content-Type': f'multipart/form-data; boundary={boundary}',
            'Content-Length': str(len(response_body)),
        }

        req = urllib.request.Request(
            url,
            headers=headers,
            data=response_body.encode(),
            method='POST'
        )

        with urllib.request.urlopen(req) as response:
            logger.info(f'Status code: {str(response.getcode())}')

    except Exception as e:
        logger.info(f'send_status(..) failed: {str(e)}')
