# Copyright (c) 2020 Anthony Potappel - LINKIT, The Netherlands.
# SPDX-License-Identifier: MIT

import os
import re
import json
import boto3
import logging
import datetime
import urllib.request

from datetime import datetime  
from datetime import timedelta
from datetime import timezone


logger = logging.getLogger()
logger.setLevel(logging.INFO)

s3_client = boto3.client('s3')
events_client = boto3.client('events')
lambda_client = boto3.client('lambda')


TIMEOUT_MINUTES = 120


def trim_alphanum(name, length=None):
    """Replace non alphanum charss with '-',
    remove leading, trailing and double '-' chars, trim length if defined int"""
    return re.sub(
        '^-|-$', '', re.sub('[-]+', '-', re.sub('[^-a-zA-Z0-9]', '-', name[0:length]))
    )


def compose_resource_name(stack_id, resource_id, length=128):
    """Compose a name of the resource based on StackId and LogicalResourceId"""
    # filter stack_name from stack_id (arn of the stack)
    stack_name = re.sub(
        '^stack-', '',
        '-'.join(stack_id.split(':')[-1]
                 .split('/')[0:-1])
    )
    # combine stack_id and resource_id in one string
    name = trim_alphanum(f'{stack_name}-{resource_id}')

    if len(name) > length:
        # re-adjust based on max length
        # allocate max. half the length on the last column
        post = name.split('-')[-1][0:length - int(length/2)]
        # allocate remaining space to all first columns, minus one for dash
        pre = name[0:length - len(post) - 1]
        # glue it together
        name = f'{pre}-{post}'
    return name


def presigned_post_url(bucket, key, expires_in=TIMEOUT_MINUTES*60):
    """Url data given to probe functions to signal SUCCESS OR FAILURE"""
    response = \
        s3_client.generate_presigned_post(bucket, key, ExpiresIn=expires_in)
    return {'Url': response['url'], 'FormData': response['fields']}


def eventrule_exists(name):
    """Check if eventrule exists"""
    try:
        if events_client.describe_rule(Name=name)['Name'] == name:
            return True
    except events_client.exceptions.ResourceNotFoundException:
        return False
    except Exception as e:
        raise Exception(e)
    return False


def targets_update(name, lambda_arn, event):
    logger.info(f'adding targets for {name}')

    expire_time = \
        datetime.now(timezone.utc) \
        + timedelta(minutes=int(event['ResourceProperties']['TimeoutInMinutes']))

    # carry event_vars over to repeating (via Eventrule) Lambda invocations
    # add expiry time for this target
    input_data = {
        'Name': name,
        'SourceEvent': {
            'ResponseURL': event['ResponseURL'],
            'StackId': event['StackId'],
            'RequestId': event['RequestId'],
            'ResourceProperties': event['ResourceProperties'],
            'LogicalResourceId': event['LogicalResourceId']
        },
        'ExpireTime': expire_time.isoformat()
    }

    response = events_client.put_targets(
        Rule=name,
        Targets=[
            {
                'Arn': lambda_arn,
                'Id': 'Self',
                'Input': json.dumps(input_data)
            }
        ]
    )
    logger.info(response)


def eventrule_update(name, pause_time_in_minutes=1):
    """Create or Update event rule"""
    # ScheduleExpression='cron(0/1 * * * ? *)',

    expression = \
        f"rate({pause_time_in_minutes} minute{pause_time_in_minutes > 1 and 's' or ''})"
    response = events_client.put_rule(
        Name=name,
        ScheduleExpression=expression,
        State='ENABLED',
        Description='string',
    )

    # RoleArn='string'
    logger.info( response )
    return {}


def eventrule_delete(name):
    """Delete Event Rule -- related targets included"""
    # expect max 1 target
    target_list = \
        events_client.list_targets_by_rule(Rule=name, Limit=1).get('Targets', [])
    target_ids = [target['Id'] for target in target_list]
    _ = events_client.remove_targets(Rule=name, Ids=target_ids)
    events_client.delete_rule(Name=name)

    return {
        'Message': f'Deleted eventrule: {name}'
    }


def eventrule(request_type, event, lambda_arn):
    """Create or Delete eventrule"""
    payload = event['ResourceProperties']

    rule_name = compose_resource_name(
        event['StackId'],
        event['LogicalResourceId'],
        length=64
    )

    if request_type == 'Delete':
        if eventrule_exists(rule_name) is False:
            return {}
        return eventrule_delete(rule_name)
    else:
        eventrule_update(
            rule_name,
            pause_time_in_minutes=int(payload.get('PauseTimeInMinutes', '1'))
        )
        targets_update(rule_name, lambda_arn, event)
    return {}


def eventrule_reinvoke(event, context):
    """
    Function should only be exited in one of these three ways:
    - return {}: eventrule stays in place
    - return {'some_key': 'some_value'}: delete eventrule + signal SUCCESS
    - Exception: delete eventrule + signal FAILED"""
    logger.info( json.dumps( event ))

    expired = datetime.now(timezone.utc) > datetime.fromisoformat(event['ExpireTime'])

    request_id = event['SourceEvent']['RequestId']
    payload = event['SourceEvent']['ResourceProperties']
    probes = payload.get('Probes', [])

    if not probes:
        if expired:
            return {'Message': 'Timeout expired without probing anything'}
        # nothing to probe -- which is fine, TimeoutInMinutes feature is still useful
        return {}

    # only lambda probes are currently supported
    lambda_probes = {
        f'lambda-probe-{str(idx)}': probe['Properties']
        for idx, probe in enumerate(probes) if probe['Provider'] == 'Lambda'
    }
    misc_probes = [
        probe['Provider']
        for probe in probes if probe['Provider'] != 'Lambda'
    ]
    if misc_probes:
        logger.info(f"Provider(s) {','.join(misc_probes)} not (yet) supported")

    probe_results = {
        item: {'bucket_key': '/'.join([os.environ['S3BucketPrefix'], item])}
        for item in lambda_probes.keys()
    }

    bucket_name = re.sub('.*:', '', os.environ['S3BucketArn'])

    # scan probe results for Status updates
    failure_detected = []
    success_detected = []
    for item, conf in probe_results.items():
        try:
            response = s3_client.get_object(
                Bucket=bucket_name,
                Key=conf['bucket_key']
            )
            contents = json.loads(response['Body'].read().decode('utf-8'))

            if contents['RequestId'] != request_id:
                # not an updated item
                continue

            status = contents.get('ResponseStatus', None)
            if not isinstance(status, str):
                continue
            if status == 'FAILED':
                failure_detected.append(item)
            elif status == 'SUCCESS':
                success_detected.append(item)

            response = contents.get('ResponseData', None)
            if response:
                logger.info(f'Probe \'{item}\' {status} with response: {json.dumps(response)}')
            else:
                logger.info(f'Probe \'{item}\' {status} without response')

        except Exception as e:
            logger.info(f"cant fetch:{conf['bucket_key']},error={str(e)}")

    if failure_detected:
        raise Exception(f"Probe(s) {str(failure_detected)} FAILED")

    if len(success_detected) == len(probe_results.keys()):
        return {'Message': 'All probes returned SUCCESS'}

    if expired:
        # probes must have failed
        raise TimeoutError

    bucket_region = \
        s3_client.get_bucket_location(Bucket=bucket_name)['LocationConstraint']

    for item, properties in lambda_probes.items():
        service_token = properties['ServiceToken']

        # append S3 Presigned data to properties
        response_url_data = presigned_post_url(
            bucket_name,
            '/'.join([os.environ['S3BucketPrefix'], item])
        )
        # overwrite URL with the Regional version to prevent 307 redirects
        response_url_data['Url'] = \
            f"https://{bucket_name}.s3-{bucket_region}.amazonaws.com/"

        event_data = {
            'RequestType': 'StatusUpdate',
            'ResourceProperties': properties,
            'ResponseUrlData': response_url_data,
            'RequestId': request_id,
            'StackId': event['SourceEvent'].get('StackId', '')
        }

        response = lambda_client.invoke(
            FunctionName=service_token,
            InvocationType='Event',
            LogType='None',
            Payload=json.dumps(event_data).encode()
        )

        # logger.info( json.dumps( response, default=str ) )
        # according to specs, Lambda event invoke-types should return 202
        # in practice we sometimes receive a 200 -- include 201 just in case
        if response['StatusCode'] not in [200, 201, 202]:
            raise Exception(f'Failed to invoke:{service_token}')

    return {}


def nofail_send(event, context, status, data):
    """Non-failing send -- log only"""
    try:
        logger.info(json.dumps({'ResponseStatus': status, 'ResponseData': data}))
        send_cfnresponse(event, context, status, data)
    except Exception as e:
        logger.info(f'send(..) failed executing requests.put(..): {str(e)}')


def handler(event, context):
    """Called by Lambda"""
    try:
        request_type = event.get('RequestType', '')

        if request_type in ['Create', 'Update']:
            # triggered as custom resource by CloudFormation
            # logger.info('event=')
            # logger.info( json.dumps( event ))
            success_count = int(event['ResourceProperties'].get('SuccessCount', 1))
            if success_count > 0:
                return eventrule(
                    request_type,
                    event,
                    context.invoked_function_arn
                )
            else:
                # success_count <= 0 bypasses the function. This property is also useful if
                # chained with resources that output 0 or 1 to signal a wait requirement
                send_cfnresponse(
                    event, context, 'SUCCESS', {}, event['LogicalResourceId']
                )
                return {}
        elif request_type in ['Delete']:
            send_cfnresponse(event, context, 'SUCCESS',
                 eventrule(
                    request_type,
                    event,
                    context.invoked_function_arn
                ),
                event['LogicalResourceId']
            )
            return {}
    except Exception as e:
        if event.get('ResponseURL', ''):
            logger.info(f'HandlerException:{str(e)}')
            send_cfnresponse(event, context, 'FAILED', {})
        else:
            logger.info(f'HandlerException:{str(e)}')
        return {}

    # assume triggered via EventRule as a repeating invocation
    if not isinstance(event, dict):
        raise ValueError(f'Input error, dictionary expected on EventRule invocation')
    if not event.get('SourceEvent', ''):
        raise ValueError(f'Input error, key SourceEvent missing on EventRule invocation')

    # pass all exceptions to ensure final eventrule_delete function gets hit
    try:
        response = eventrule_reinvoke(event, context)
        if not response:
            # re-Invoke initiated -- return without hitting eventrule_delete
            return {}
        # response without exceptions -- exit with SUCCESS
        nofail_send(event.get('SourceEvent', {}), context, 'SUCCESS', response)
    except TimeoutError:
        nofail_send(event.get('SourceEvent', {}), context, 'FAILED', {'Message': 'TIMEOUT'})
        pass
    except Exception as e:
        nofail_send(event.get('SourceEvent', {}), context, 'FAILED', {'Message': str(e)})
        pass

    # in any case, except re-Invoke, delete eventrule
    # provided it still exists
    if eventrule_exists(event.get('Name', '')) is True:
        eventrule_delete(event['Name'])


def send_cfnresponse(
        event, context, response_status, response_data,
        physicalResourceId=None, noEcho=False
    ):
    response_url = event['ResponseURL']

    response_body = {
        'Status' : response_status,
        'Reason': f'See the details in CloudWatch Log Stream: {context.log_group_name}',
        'PhysicalResourceId': physicalResourceId or context.log_stream_name,
        'StackId': event['StackId'],
        'RequestId': event['RequestId'],
        'LogicalResourceId': event['LogicalResourceId'],
        'NoEcho': noEcho,
        'Data': response_data
    }

    json_responseBody = json.dumps(response_body)

    headers = {
        'content-type': '',
        'content-length': str(len(json_responseBody))
    }

    try:
        req = urllib.request.Request(
            response_url,
            data=json_responseBody.encode(),
            headers=headers,
            method='PUT'
        )
        with urllib.request.urlopen(req) as response:
            logger.info(f'Status code: {str(response.getcode())}')
    except Exception as e:
        logger.info(f'send(..) failed executing requests.put(..): {str(e)}')
