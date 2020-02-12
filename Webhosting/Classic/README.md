
# Fargate Cluster with service updates via CodePipeline

## Build Instructions
For both the automated and semi-automated build, ensure AWS CLI is installed

To save time, and to guarantuee a consistent build, the fully automated method is recommended. It accepts the same vanilla CloudFormation code, as it uses AWS CLI underneath. It is tested to work on modern Linux distributions, MacOS and should integrate with most pipeline tools.

The semi-automated method only depends on AWS CLI.


### Fully automated via Makefile
'''
# go to root folder of this project where Makefile resides

# deploy
make deploy template=Webhosting/Classic/template.yaml

# delete
make delete template=Webhosting/Classic/template.yaml
'''

### Semi-Automated
'''
# Create an S3 Bucket 
aws s3  ...

# Get name/ prefix

# run pre_process.sh, this builds a zipfile and populates a parameters file
CONFIGURATION_BUCKET= .... 


# package stack


# deploy stack


# delete 

# note: S3 bucket needs to be cleaned up 
'''

## Usage Instructions
TBD
