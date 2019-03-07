#!/bin/bash

# This is the 2nd pass of the run_tdnn_1c_1 for 
# speaker adaptation using s-vectors. It takes
# the chain model trained in the first pass as the 
# starting point and uses the first-pass decoding
# to train the s-vectors.

set -e

# configs for 'chain'
stage=0
train_stage=0
get_egs_stage=-10
dir=exp/chain_cleaned/tdnnf_1a_2
train_set=train_cleaned
test_sets=dev
nj=40

# configs for transfer learning from 1st pass

# training options
# training chunk-options
chunk_width=140,100,160
dropout_schedule='0,0@0.20,0.3@0.50,0'
common_egs_dir=
xent_regularize=0.1

# training options
srand=0
remove_egs=true
reporting_email=

primary_lr_factor=0.25 # learning-rate factor for all except last layer in transferred source model
nnet3_affix=_cleaned

phone_lm_scales="1,1" # comma-separated list of positive integer multiplicities
                       # to apply to the different source data directories (used
                       # to give the RM data a higher weight).

# model and dirs for source model used for transfer learning
src_mdl=./exp/chain_cleaned/tdnnf_1a/final.mdl # input chain model

src_mfcc_config=./conf/mfcc_hires.conf # mfcc config used to extract higher dim
src_ivec_extractor_dir=exp/nnet3/ivectors_${train_set}_sp_hires # source ivector extractor dir used to extract ivector for
                         # source data and the ivector for target data is extracted using this extractor.
                         # It should be nonempty, if ivector is used in source model training.

src_lang=data/lang_chain        # source lang directory used to train source model.
                                # new lang dir for transfer learning experiment is prepared
                                # using source phone set phone.txt and lexicon.txt in src lang dir and
                                # word.txt target lang dir.
src_dict=data/local/dict_nosp  # dictionary for source dataset containing lexicon.txt,
                                            # nonsilence_phones.txt,...
                                            # lexicon.txt used to generate lexicon.txt for
                                            # src-to-tgt transfer.

src_tree_dir=exp/chain_cleaned/tree      # chain tree-dir for src data;
                                         # the alignment in target domain is
                                         # converted using src-tree

xent_regularize=0.1
# End configuration section.

echo "$0 $@"  # Print the command line for logging

. ./cmd.sh
. ./path.sh
. ./utils/parse_options.sh

if ! cuda-compiled; then
  cat <<EOF && exit 1
This script is intended to be used with GPUs but you have not compiled Kaldi with CUDA
If you want to use GPUs (and have them), go to src/, and configure and make on a machine
where "nvcc" is installed.
EOF
fi

# The iVector-extraction and feature-dumping parts are the same as the standard
# nnet3 setup, and you can skip them by setting "--stage 8" if you have already
# run those things.

# dirs for src-to-tgt transfer experiment
lang_dir=data/lang_chain   # lang dir for target data.
lang_src_tgt=data/lang_chain # This dir is prepared using phones.txt and lexicon from
                              # source(WSJ) and and wordlist and G.fst from target(RM)
lat_dir=exp/chain_lats

required_files="$src_mfcc_config $src_mdl $src_lang/phones.txt $src_dict/lexicon.txt $src_tree_dir/tree"

backup_ivec_dir=exp/nnet3${nnet3_affix}/backup
if [ $stage -le -1 ]; then
    mkdir -p $backup_ivec_dir
    cp -r exp/nnet3${nnet3_affix}/ivectors_${train_set}_sp_hires $backup_ivec_dir
    cp -r exp/nnet3${nnet3_affix}/ivectors_${test_sets}_hires $backup_ivec_dir
fi

for f in $required_files; do
  if [ ! -f $f ]; then
    echo "$0: no such file $f" && exit 1;
  fi
done

if [ $stage -le 3 ]; then
    # Create onehot ivectors for training and dev data
  local/nnet3/create_onehot_ivectors.sh  --stage $stage \
                       --ivector-dir exp/nnet3${nnet3_affix}/ivectors_${train_set}_sp_hires \
                       --spk2utt data/${train_set}_sp_hires/spk2utt \
                       --nnet3-affix "$nnet3_affix" || exit 1;

  local/nnet3/create_onehot_ivectors.sh --stage $stage \
                       --ivector-dir exp/nnet3${nnet3_affix}/ivectors_${test_sets}_hires \
                       --spk2utt data/${test_sets}_hires/spk2utt \
                       --nnet3-affix "$nnet3_affix" || exit 1;

fi

src_mdl_dir=`dirname $src_mdl`
ivec_opt="--online-ivector-dir ${backup_ivec_dir}/ivectors_${test_sets}_hires"

# Copying ivectors across frames
if [ $stage -le 4 ]; then
  #local/nnet3/copy_across_frames.sh \
  #  --dir exp/nnet3${nnet3_affix}/ivectors_${train_set}_sp_hires \
  #  --data data/${train_set}_sp_hires

  local/nnet3/copy_across_frames.sh \
    --dir exp/nnet3${nnet3_affix}/ivectors_${test_sets}_hires \
    --data data/${test_sets}_hires
fi

if [ $stage -le 5 ]; then
  # Get the alignments as lattices (gives the chain training more freedom).
  # use the same num-jobs as the alignments
  steps/nnet3/align_lats.sh --nj 10 --cmd "$train_cmd" $ivec_opt \
    --generate-ali-from-lats true \
    --acoustic-scale 1.0 --extra-left-context-initial 0 --extra-right-context-final 0 \
    --frames-per-chunk 150 \
    --scale-opts "--transition-scale=1.0 --self-loop-scale=1.0" \
    data/${test_sets}_hires $lang_src_tgt $src_mdl_dir $lat_dir;
  rm $lat_dir/fsts.*.gz # save space
fi

# Now we remove the first few layers from transferred model and 
# add our one-hot ivectors and a transformation layer to convert
# them into 100 dimensional i-vectors.
if [ $stage -le 6 ]; then
  ivector_dim=$(< data/${test_sets}_hires/spk2utt wc -l)
  output_opts="l2-regularize=0.015"
  mkdir -p $dir/configs

  echo "$0: Create neural net configs using the xconfig parser for";
  echo " generating new layers, that are specific to rm. These layers ";
  echo " are added to the transferred part of the wsj network.";
  num_targets=$(tree-info --print-args=false $src_tree_dir/tree |grep num-pdfs|awk '{print $2}')
  learning_rate_factor=$(echo "print 0.5/$xent_regularize" | python)
  
  
  cat <<EOF > $dir/configs/network.xconfig
 
  input name=ivector dim=$ivector_dim
 ## adding the layers for chain branch
  relu-batchnorm-layer name=svector_hidden dim=50 l2-regularize=0.001 input=ivector
  relu-batchnorm-layer name=svector dim=100 l2-regularize=0.001 target-rms=0.1 input=svector_hidden

  input name=input dim=40
  output-layer name=output include-log-softmax=false dim=$num_targets $output_opts
EOF
 
  steps/nnet3/xconfig_to_configs.py \
    --xconfig-file  $dir/configs/network.xconfig  \
    --config-dir $dir/configs/
fi

## TODO: At present, after this stage, we have to manually edit the final.config
## file. This needs to be automated.

if [ $stage -le 7 ]; then
  # Set the learning-rate-factor to be primary_lr_factor for transferred layers "
  # and adding new layers to them.
  $train_cmd $dir/log/generate_input_mdl.log \
    nnet3-copy \
      --nnet-config=$dir/configs/final.config \
      --edits="set-learning-rate-factor name=* learning-rate-factor=0.0; set-learning-rate-factor name=svector* learning-rate-factor=1.0" $src_mdl - \| \
      nnet3-init --srand=1 - $dir/configs/final.config $dir/input.raw  || exit 1;
fi

if [ $stage -le 8 ]; then
  echo "$0: compute {den,normalization}.fst using weighted phone LM."
  steps/nnet3/chain/make_weighted_den_fst.sh --cmd "$train_cmd" \
    --num-repeats $phone_lm_scales \
    --lm-opts '--num-extra-lm-states=200' \
    $src_tree_dir $lat_dir $dir || exit 1;
fi

if [ $stage -le 9 ]; then
  if [[ $(hostname -f) == *.clsp.jhu.edu ]] && [ ! -d $dir/egs/storage ]; then
    utils/create_split_dir.pl \
     /export/b0{3,4,5,6}/$USER/kaldi-data/egs/rm-$(date +'%m_%d_%H_%M')/s5/$dir/egs/storage $dir/egs/storage
  fi
  # exclude phone_LM and den.fst generation training stage
  if [ $train_stage -lt -4 ]; then train_stage=-4 ; fi

  ivector_dir="exp/nnet3${nnet3_affix}/ivectors_${test_sets}_hires"

  # we use chain model from source to generate lats for target and the
  # tolerance used in chain egs generation using this lats should be 1 or 2 which is
  # (source_egs_tolerance/frame_subsampling_factor)
  # source_egs_tolerance = 5
  chain_opts=(--chain.alignment-subsampling-factor=1)
  steps/nnet3/chain/train.py --stage=$train_stage ${chain_opts[@]}\
    --cmd="$decode_cmd" \
    --feat.online-ivector-dir=$ivector_dir \
    --feat.cmvn-opts="--norm-means=false --norm-vars=false" \
    --chain.xent-regularize $xent_regularize \
    --chain.leaky-hmm-coefficient=0.1 \
    --chain.l2-regularize=0.0 \
    --chain.apply-deriv-weights=false \
    --chain.lm-opts="--num-extra-lm-states=2000" \
    --trainer.dropout-schedule $dropout_schedule \
    --trainer.add-option="--optimization.memory-compression-level=2" \
    --trainer.srand=$srand \
    --trainer.max-param-change=2.0 \
    --trainer.input-model $dir/input.raw \
    --trainer.num-epochs=20 \
    --trainer.frames-per-iter=1500000 \
    --trainer.optimization.num-jobs-initial=2 \
    --trainer.optimization.num-jobs-final=3 \
    --trainer.optimization.initial-effective-lrate=0.001 \
    --trainer.optimization.final-effective-lrate=0.0001 \
    --trainer.num-chunk-per-minibatch=128 \
    --egs.chunk-width=150 \
    --egs.dir="$common_egs_dir" \
    --egs.opts="--frames-overlap-per-eg 0" \
    --cleanup.remove-egs=$remove_egs \
    --use-gpu=true \
    --reporting.email="$reporting_email" \
    --feat-dir=data/${test_sets}_hires \
    --tree-dir=$src_tree_dir \
    --lat-dir=$lat_dir \
    --dir=$dir  || exit 1;

fi

if [ $stage -le 10 ]; then
  # Note: it might appear that this $lang directory is mismatched, and it is as
  # far as the 'topo' is concerned, but this script doesn't read the 'topo' from
  # the lang directory.
  test_ivec_opt="--online-ivector-dir exp/nnet3${nnet3_affix}/ivectors_${test_sets}_hires"

  utils/mkgraph.sh --self-loop-scale 1.0 $lang_src_tgt $dir $dir/graph
  steps/nnet3/decode.sh --acwt 1.0 --post-decode-acwt 10.0 \
    --scoring-opts "--min-lmwt 1" \
    --nj 20 --cmd "$decode_cmd" $test_ivec_opt \
    $dir/graph data/dev_hires $dir/decode || exit 1;
  steps/lmrescore_const_arpa.sh --cmd "$decode_cmd" data/lang data/lang_rescore \
    data/${test_sets}_hires ${dir}/decode ${dir}/decode_${test_sets}_rescore || exit 1
fi
wait;
exit 0;
