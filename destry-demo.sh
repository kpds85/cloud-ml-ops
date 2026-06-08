#!/bin/bash
set -e

# Variables (should match create-demo.sh)
STACK_NAME=sagemaker-greengrass-demo
S3_BUCKET=demo-bucket

echo "1. Cleaning up S3 files..."
aws s3 rm s3://$S3_BUCKET/dataset/ --recursive || true
aws s3 rm s3://$S3_BUCKET/models/ --recursive || true

echo "2. Deleting S3 bucket if empty..."
aws s3 rb s3://$S3_BUCKET || true

echo "3. Deleting CloudFormation stack ($STACK_NAME)..."
aws cloudformation delete-stack --stack-name $STACK_NAME

echo "Waiting for stack deletion to complete..."
aws cloudformation wait stack-delete-complete --stack-name $STACK_NAME
echo "CloudFormation stack deleted."

echo "4. (Manual) Remove Greengrass components, deployments, and SageMaker model registry entries if not deleted automatically via stack."
echo "   Please use the AWS Console for any remaining Greengrass, SageMaker Model Registry, or IoT Thing cleanup if needed."

echo "5. Cleaning up local files..."
rm -f component-recipe.json || true

echo "Demo resources destroyed. All done!"
