from sagemaker.processing import ScriptProcessor, ProcessingInput, ProcessingOutput
from sagemaker.workflow.steps import ProcessingStep, TrainingStep, RegisterModel
from sagemaker.workflow.pipeline import Pipeline
from sagemaker.estimator import Estimator
from sagemaker.model import Model
import sagemaker

# Set up AWS account/session details
role = "arn:aws:iam::099014786457:role/SageMakerExecutionRole"  # IAM role for SageMaker jobs
default_bucket = "demo-bucket"                               # S3 bucket for input/output data
session = sagemaker.Session()                                   # Session object for pipeline

# Define types of EC2 instance to use for steps
processing_instance_type = "ml.m5.large"
training_instance_type = "ml.m5.large"

# STEP 1: Preprocessing
# Create a processor for custom preprocessing (runs arbitrary Python or shell scripts)
preprocess_processor = ScriptProcessor(
    image_uri="public.ecr.aws/y9d4r6b4/python:3.10",           # Docker image with Python runtime
    command=["python3"],                                       # Entrypoint command
    instance_type=processing_instance_type,
    instance_count=1,
    role=role
)
# Define the pipeline step that runs the processor on your preprocessing script
preprocess_step = ProcessingStep(
    name="PreProcess",                                         # Logical name in pipeline
    processor=preprocess_processor,                            # Run with ScriptProcessor above
    code="dummy_preprocess.py",                                # Python script to run for preprocessing
    outputs=[ProcessingOutput(output_name="preprocessed",      # Output artifact named "preprocessed"
                             source="/opt/ml/processing/output")] # This folder inside container becomes S3 output
)

# STEP 2: Training
# Define estimator: how training is performed, what image/script to use
estimator = Estimator(
    image_uri="public.ecr.aws/y9d4r6b4/python:3.10",            # Training Docker image
    entry_point="dummy_train.py",                               # Training script to run
    role=role,                                                  # IAM role for permissions
    instance_count=1,                                           # Number of EC2 instances
    instance_type=training_instance_type,
    output_path=f"s3://{default_bucket}/models/"                # Where model artifact will be saved in S3
)
# Define pipeline step for training (depends on preprocess output)
training_step = TrainingStep(
    name="TrainModel",
    estimator=estimator,
    inputs={
        "train": preprocess_step.outputs["preprocessed"]         # Use output from preprocessing step as training input
    }
)

# STEP 3: Model Registration
# Define a Model object for inference. Links to trained model data & container image.
model = Model(
    image_uri="public.ecr.aws/y9d4r6b4/python:3.10",                 # Inference image URI
    model_data=training_step.properties.ModelArtifacts.S3ModelArtifacts,  # S3 path to model artifact (produced by training_step)
    role=role
)
# Register the model in SageMaker Model Registry for versioning, tracking, deployment
register_step = RegisterModel(
    name="RegisterTrainedModel",
    estimator=estimator,                                    # Can link back to original estimator
    model=model,
    content_types=["text/plain"],                            # What input data types the model accepts (for demo, just text)
    response_types=["text/plain"],                           # What output formats are returned
    approval_status="Approved",                              # Immediate approval for deployment
    model_package_group_name="DemoModelGroup"                # Logical registry group for all related models
)

# STEP 4: Postprocessing
# Create a ScriptProcessor for postprocessing/metrics
postprocess_processor = ScriptProcessor(
    image_uri="public.ecr.aws/y9d4r6b4/python:3.10",
    command=["python3"],
    instance_type=processing_instance_type,
    instance_count=1,
    role=role
)
# Define postprocessing step in the pipeline
postprocess_step = ProcessingStep(
    name="PostProcess",
    processor=postprocess_processor,
    code="dummy_postprocess.py",                             # Python script to run for postprocessing
    inputs=[ProcessingInput(source=preprocess_step.outputs["preprocessed"].destination,  # Use preprocessing output again
                            destination="/opt/ml/processing/input")]
)

# PIPELINE DEFINITION
pipeline = Pipeline(
    name="DemoMultipleStepPipeline",                         # Pipeline name
    steps=[preprocess_step, training_step, register_step, postprocess_step],  # List of steps (executed in order; later steps depend on outputs of earlier ones)
    sagemaker_session=session
)

# PIPELINE DEPLOYMENT AND EXECUTION
pipeline.upsert(role_arn=role)        # Register/update pipeline definition in SageMaker
execution = pipeline.start()          # Start pipeline execution (can monitor status)
print(f"Pipeline execution started: {execution.arn}") # Prints unique ARN for the pipeline run
