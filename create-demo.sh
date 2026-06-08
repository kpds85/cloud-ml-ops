#!/bin/bash
set -e

STACK_NAME=sagemaker-greengrass-demo
CF_TEMPLATE=demo-stack.yaml
S3_BUCKET=demo-bucket

echo "1. Creating CloudFormation stack ($STACK_NAME)..."
aws cloudformation create-stack \
  --stack-name $STACK_NAME \
  --template-body file://$CF_TEMPLATE \
  --capabilities CAPABILITY_NAMED_IAM

echo "Waiting for stack creation to complete..."
aws cloudformation wait stack-create-complete --stack-name $STACK_NAME
echo "CloudFormation stack created."

echo "2. Creating dummy dataset..."
echo -e "image_id,label\n1,none\n2,damage" > dummy_dataset.csv
aws s3 cp dummy_dataset.csv s3://$S3_BUCKET/dataset/dummy_dataset.csv
rm dummy_dataset.csv

echo "3. Simulate model training and upload dummy model..."
echo "FAKE_MODEL_CONTENT" > model.txt
aws s3 cp model.txt s3://$S3_BUCKET/models/model-v1.txt
rm model.txt

echo "4. Submitting SageMaker Pipeline for training workflow..."
python3 submit_pipeline.py

echo "5. Waiting for SageMaker Pipeline execution to complete..."
# Optionally, the Python script can print execution ARN and monitor status.
# Or you can use the AWS CLI to poll (shown below).

# (Optional) If your Python script prints the pipeline execution ARN, you can monitor like:
# PIPELINE_EXEC_ARN=<value from python3 submit_pipeline.py output>
# aws sagemaker describe-pipeline-execution --pipeline-execution-arn $PIPELINE_EXEC_ARN

echo "6. Proceeding with Greengrass component creation and other steps."
# Follow with automated/model registry logic, Greengrass creation script, etc.

echo "7. Create Greengrass component recipe..."
cat > component-recipe.json <<EOF
{
  "RecipeFormatVersion": "2020-01-25",
  "ComponentName": "DemoModelComponent",
  "ComponentVersion": "1.0.0",
  "ComponentDescription": "Fake model for demo",
  "Manifests": [{
    "Platform": {"os": "linux"},
    "Artifacts": [
      { "Uri": "s3://$S3_BUCKET/models/model-v1.txt", "Name": "model.txt" }
    ],
    "Lifecycle": {
      "Run": "echo Running demo inference && cat {artifacts:decompressedPath}/model.txt"
    }
  }]
}
EOF

echo "8. NOTE: Manual Step! Register the Greengrass component using component-recipe.json in the AWS Console"
echo "   (You must use AWS Console to create the component from recipe. Press enter when done.)"
read -r

echo "9. Press enter to Provision a Greengrass Core device with Thing Name \"MyGreengrassCore\"."
read -r
./provision-greengrass-device.sh

echo "10. NOTE: Deploy DemoModelComponent (1.0.0) to registered Greengrass Core device."
echo "   (Follow the Greengrass Console wizard or docs; your core device must be registered and run deployment.)"
