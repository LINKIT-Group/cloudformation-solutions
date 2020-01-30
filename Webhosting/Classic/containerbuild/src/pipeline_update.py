# Copyright (c) 2020 Anthony Potappel - LINKIT, The Netherlands.
# SPDX-License-Identifier: MIT

import json
import logging
import copy
import boto3
import urllib.request

from collections import defaultdict

logger = logging.getLogger()
logger.setLevel(logging.INFO)

client = boto3.client('codepipeline')


"""Convert nested list to single"""
flatten_list = lambda l: [item for sublist in l for item in sublist]


def change_dictkeys(obj, function):
    """Apply function to each dict-key"""
    if isinstance(obj, list):
        return [change_dictkeys(v, function) for v in obj]
    if isinstance(obj, dict):
        return {function(k): change_dictkeys(v, function) for k, v in obj.items()}
    return obj


def mapper(template, config):
    """Map template to list based on (env-)config"""
    # boto3 spec updates; dictkey rule exception and runOrder type
    template['configuration'] = \
        change_dictkeys(template['configuration'], lambda k: k[:1].upper() + k[1:])
    template['runOrder'] = int(template.get('runOrder', 1))
  
    if template['name'] not in config:
        actions = [template]
    else:
        # map parameter sets
        _map = defaultdict(list)
        for key, vlist in config[template['name']].items():
            for y, val in enumerate(vlist.split(',')):
                _map[y].append({'name': key, 'value': val, 'type': 'PLAINTEXT'})
    
        # append existing (global) env vars if set
        envvars = \
            json.loads(template['configuration'].get('EnvironmentVariables', '[]'))
        if envvars:
            _map = {k: v + envvars for k, v in _map.items()}
    
        # create action-list -- name and Environment are unique per action
        actions = [copy.deepcopy(template) for _ in _map.keys()]
        for idx, varstr in enumerate([
            json.dumps(v, separators=(',', ':')) for _, v in sorted(_map.items())
        ]):
            actions[idx]['name'] = f"{actions[idx]['name']}-{idx}"
            actions[idx]['configuration']['EnvironmentVariables'] = varstr
    return actions


def main(event):
    """Create|Update Pipeline"""
    request = event['RequestType']
    logger.info(f"Request:{request}")
  
    if request == 'Delete':
        return {"Message": "SKIPPED: delete via source Pipeline"}
    elif request not in ['Create', 'Update']:
        raise ValueError(f"RequestType={str(request)}")
  
    payload = event['ResourceProperties']
    logger.info(json.dumps(payload))
  
    # create named list of stage-updates
    stages_new = {}
    for stage in payload['Stages']:
        # update dictkeys to meet boto3 spec
        spec = change_dictkeys(stage['StageDeclaration'], lambda k: k[:1].lower() + k[1:])
  
        # get (updated) action-list via mapper function
        config = {
            action['SourceAction']: action['EnvironmentVariables']
            for action in stage.get('MapConfig', [])}
        spec['actions'] = flatten_list([
            mapper(action, config) for action in spec.get('actions', [])])
  
        # insert to new stages list
        stages_new[str(spec['name'])[:100]] = \
            {'order': int(stage['StageOrder']), 'spec': spec}
  
    # existing Pipeline
    pipeline = client.get_pipeline(name=payload['Target'])['pipeline']
    # insert existing stages not included in update
    pipeline['stages'] = \
        [stage for stage in pipeline['stages'] if stage['name'] not in stages_new.keys()]
    # insert updated stages, enforce order
    for stage in sorted(stages_new.values(), key = lambda item: item["order"]):
        pipeline['stages'].insert(stage['order'], stage['spec'])
    response = client.update_pipeline(pipeline=pipeline)
    logger.info(json.dumps(response))
    return {"Message": f"SUCCESS: updated {response['pipeline']['name']}"}


def handler(event, context):
    """Called by Lambda"""
    try:
        send(
            event, context, 'SUCCESS',
            main(event),
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

