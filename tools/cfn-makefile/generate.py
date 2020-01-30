#!/usr/bin/env python3
# --------------------------------------------------------------------
# Copyright (c) 2020 Anthony Potappel - LINKIT, The Netherlands.
# SPDX-License-Identifier: MIT
# --------------------------------------------------------------------

import os
import re
import sys
import time
import datetime


epoch_in_milliseconds = lambda: round(time.time()*10**3)
iso_8601_date = lambda: f'{datetime.datetime.utcnow().isoformat()}+00:00'

def generate_makefile(template, filemap):
    """Read file, replace {{ parameter-key }} with {{ parameter-value } and
    write updated contents"""
    if not isinstance(template, str):
        raise TypeError('template should be formatted as a string')
    if not isinstance(filemap, dict):
        raise TypeError('filemap should be formatted as a dictonary')

    # original template file
    with open(template, 'r') as stream:
        contents = stream.read().strip()

    # iterate over replace labels ( {{ ... }} )
    matches = set([m for m in re.findall("{{ ?.*? ?}}", contents)])
    for match in matches:
        key = re.sub('^{{ ?| ?}}$', '', match)
        item = filemap.get(key)

        if isinstance(item, str) and os.path.isfile(item):
            # file contents to be inserted
            with open(item, 'r') as stream:
                insert = stream.read().strip()
            # makefile requires $ to be escaped by $
            insert = re.sub('\$', '$$', insert)
        elif isinstance(item, str):
            insert = item
        elif isinstance(item, int):
            insert = str(item)
        elif hasattr(item, '__call__'):
            insert = str(item())
        else:
            raise TypeError(f'Unsupported replacement type:{type(item)} for {key}')

        # use this file injection type method over re.sub to do genuine
        # as-is type replacement -- i.e. no espacing requirements
        position = re.search(re.escape(match), contents)
        contents = contents[0:position.start()] + insert + contents[position.end():]
    return contents


filemap = {
    'AUTO_GENERATED_NOTICE': 'src/auto_generated_notice.txt',
    'EPOCH_IN_MILLISECONDS': epoch_in_milliseconds,
    'ISO_8601_DATE': iso_8601_date,
    'CFN_FUNCTIONS': 'src/cfn_functions.sh',
    'GIT_FUNCTIONS': 'src/git_functions.sh'
}

sys.stdout.write(generate_makefile('src/Makefile.template', filemap))
